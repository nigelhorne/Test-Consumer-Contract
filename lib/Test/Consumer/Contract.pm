package Test::Consumer::Contract;

=head1 NAME

Test::Consumer::Contract - check a reader against the keys its producer promises

=head1 VERSION

Version 0.03

=head1 SYNOPSIS

A distribution declares what its value object promises, who produces it, who
reads it, and why each exception is safe:

    use Test::Most;
    use Test::Consumer::Contract qw(run_consumer_contract);

    run_consumer_contract(
        source        => 'Widget::Maker',
        # Required: the calls that hand a result to the caller, as this
        # producer spells them.  None of them has to be a geocoder.
        methods       => [qw(make build)],
        value_object  => {
            class   => 'Widget',
            from    => { latitude => 1, longitude => 2 },
            derives => { x => 1, y => 2 },
        },
        guaranteed  => [qw(x y)],
        conditional => { colour => 'only the painted path sets it' },
        producers   => { 'lib/Widget/Maker.pm' => [qw(x y colour)] },
        consumers   => {
            'Widget-User/lib/Widget/User.pm' => {
                may_rely_on => {
                    render => { colour => 'defaults to undef on purpose' },
                },
            },
        },
        ignored     => [['Widget-List/', 'reads its own normalised output']],
        accessors   => [qw(x y)],   # documented accessors a consumer may read
        not_accessors => {          # documented, but not a slot of one result
            new             => 'the constructor',
            ACCURACY_LEVELS => 'a class constant',
        },
        inspection  => [qw(can isa DOES)],
    );

    done_testing();

=head1 DESCRIPTION

C<run()> runs these checks, each as one subtest, in this order:

=over 4

=item 1. the producers still set the keys the contract claims

Each file named in C<producers> (and C<workspace_producers>) is read and each key
it is responsible for must still be assigned there, so a producer that quietly
stops stamping a key fails.  POD and comments are removed first: a key shown in
a synopsis is documentation of the promise, not the producer keeping it.

=item 2. the value object still derives what it promises

When C<value_object> has C<derives>, an object is built from C<from> and each
derived accessor must return the value given.  A value object that cannot be
found is skipped; one that is found but does not compile, or whose constructor
dies, fails.

=item 3. registered consumers read only what every producer sets

Each file named in C<consumers> is scanned for reads of a result.  A read of a
key in C<guaranteed> is fine; a read of anything else is reported with its file,
line, sub and the reason the key is a problem, unless the read is registered
under C<may_rely_on> keyed by the name of the enclosing sub.  An entry that is no
longer read is reported as stale, so the registry keeps describing the code.

=item 4. the accessor lists match the value object, in both directions

The value object's documented accessors are its C<=head2> headings and the
public subs it defines.  Each one the declaration names in C<accessors> or
C<not_accessors> must be an accessor the value object really has, and - the
direction that matters when a value object grows - each one the value object
documents must be accounted for in C<accessors>, C<not_accessors> or
C<conditional>.  So a value object that gains a documented accessor cannot leave
the declaration behind: the check fails, naming the accessor and the three
places to put it.

=item 5. every discovered consumer is registered

Files in sibling distributions that receive a result but are named in neither
C<consumers> nor C<ignored> fail the check, so a new consumer cannot slip past
check 3 unnoticed.  A consumer is not necessarily a module: a program without an
extension is discovered too, when it starts with a shebang.

=back

Checks 3 and 5 need the sibling distributions that share a workspace; when a
distribution named in C<require_workspace> is absent they skip with a
diagnostic.  Checks 2 and 4 need the value object's own file, which C<include>
puts in reach.  This is a static, lexical check: it reads source, it does not
run the producer.

=head1 REQUIREMENTS

The caller must load a test module (L<Test::Most> or L<Test::More>) and call
C<done_testing()> after C<run_consumer_contract()>; this module adds subtests
but does not end the plan.

=head1 CONFIGURATION

C<%Test::Consumer::Contract::config> holds the tunables, in the shape
L<Object::Configure> produces, so a caller (or a configuration layer) can
change them before C<new()> is called.  Each object takes a copy when it is
built, so a later change does not reach an object that already exists.

    Key                Meaning                                      Default
    -----------------  -------------------------------------------  ---------------------
    sibling_dirs       directories scanned in a sibling dist        lib bin t
    own_dirs           directories scanned in dist_root             lib bin scripts
    source_extensions  file extensions that hold Perl source        pm t pl PL pm6
    skipped_dirs       directory names never descended into         blib xt inc local
                                                                    node_modules .git
                                                                    .build
    messages           message key => template, over the built-in   (empty)

C<new()> does not call L<Object::Configure/configure> itself: that would let an
environment variable rewrite a contract that is meant to be written in code.

=cut

use 5.014;
use strict;
use warnings;

# Sub::Private reads its mode as it wraps each :Private sub, at CHECK time, so
# enforce mode has to be chosen before the module is loaded.  Enforce mode is
# the one that works with method calls ($self->_helper).
BEGIN { $Sub::Private::config{'mode'} = 'enforce' }

use autodie qw(:all);
use Carp qw(croak confess);
use Cwd qw(abs_path getcwd);
use Exporter 'import';
use File::Basename qw(basename dirname);
use File::Find ();
use File::Spec;
use List::Util qw(first);
use Module::Runtime qw(is_module_name module_notional_filename require_module);
use Params::Get qw(get_params);
use Params::Validate::Strict qw(validate_strict);
use Readonly;
use Return::Set qw(set_return);
use Scalar::Util qw(blessed looks_like_number);
use Sub::Private;
use Sub::Protected;
use Test::More;
use Text::Balanced qw(extract_bracketed);
use lib ();

our @EXPORT_OK = qw(run_consumer_contract);

our $VERSION = '0.03';

# ---------------------------------------------------------------------------
# Constants and configuration
# ---------------------------------------------------------------------------

# The options new() requires; the rest have defaults.
Readonly::Array my @REQUIRED => qw(source guaranteed methods);

# How a read outside any named sub is reported, and how the contract spells
# the separator between directories whatever the platform uses.
Readonly::Scalar my $FILE_SCOPE => '(file scope)';
Readonly::Scalar my $SEPARATOR  => '/';
Readonly::Scalar my $SHEBANG    => '#!';

# The two kinds of read a consumer can make of a result.
Readonly::Scalar my $KIND_KEY      => 'key';
Readonly::Scalar my $KIND_ACCESSOR => 'accessor';

# Diagnostics are indented one tab, one item per line.
Readonly::Scalar my $DIAG_INDENT => "\n\t";

# The delimiters Text::Balanced balances a block by: braces, skipping any that
# sit inside a quoted string, such as the key in $_->{'}'}.
Readonly::Scalar my $BLOCK_DELIMITERS => q({}"');

# Lexical building blocks shared by the scanner's passes, so that every pass
# agrees on what a variable, an assignment and a key read look like.  The
# assignment refuses '==' and '=~': neither puts a value into the variable.
Readonly::Scalar my $VARIABLE   => qr/\$[A-Za-z_]\w*/;
Readonly::Scalar my $DECLARATOR => qr/(?:my|our|local)?\s*/;
Readonly::Scalar my $ASSIGNMENT => qr/\s*=(?![=~])\s*/;
Readonly::Scalar my $KEY_READ   => qr/\s*->\s*\{\s*['"]?(\w+)['"]?\s*\}/;
Readonly::Scalar my $NEVER      => qr/(?!)/;

# A producing call written with its class: Widget::Maker->fetch or
# Widget::Maker::fetch.
Readonly::Scalar my $QUALIFIED_NAME => qr/\A([\w:]+)\s*(?:->|::)\s*(\w+)\z/;

# A message placeholder: {name}, or {name:%fmt} for a sprintf conversion.  Only
# the conversions that format a value are allowed - never %n, which writes.
Readonly::Scalar my $PLACEHOLDER => qr/\{(\w+)(?::(%[-+ 0#]*\d*(?:\.\d+)?[sdfgeExXobu]))?\}/;

# The tunables (see CONFIGURATION).  A package hash rather than constants so a
# configuration layer can reach them.
our %config = (
	sibling_dirs      => [qw(lib bin t)],
	own_dirs          => [qw(lib bin scripts)],
	source_extensions => [qw(pm t pl PL pm6)],
	skipped_dirs      => [qw(blib xt inc local node_modules .git .build)],
	messages          => {},
);

# Every user-facing string, by key.  A value is a template, or a hash of
# templates chosen by the 'context' argument (gender, say) or by 'count'
# (zero/one/other).  See i18n().
Readonly::Hash my %MESSAGES => (
	'i18n.unknown'          => "no message called '{key}'",
	'list.and'              => '{head} and {last}',
	'argument.invalid'      => '{package}::{routine}(): {error}',
	'argument.missing'      => "{package}::{routine}() needs a '{argument}'",
	'option.unknown'        => '{package}::new() does not know the option(s): {options}',
	'option.required'       => "{package}::new() needs a '{option}'",
	'option.invalid'        => '{package}::new(): {error}',
	'option.ignored'        => "{package}::new(): each 'ignored' rule must be [prefix, reason], not {rule}",
	'option.consumer'       => "{package}::new(): consumer '{consumer}' must be { may_rely_on => { sub => { key => why } } }",
	'option.class'          => "{package}::new(): value_object needs a 'class' that is a module name, not '{class}'",
	'option.directory'      => "{package}::new(): {option} '{path}' is not a directory: {error}",
	'check.producers'       => 'the producers still set the keys the contract claims',
	'check.derivation'      => '{class} derives {keys}',
	'check.consumers'       => 'registered consumers read only what every producer sets',
	'check.accessors'       => 'the accessor list matches the value object',
	'check.discovery'       => 'every discovered consumer is registered',
	'file.readable'         => '{file} is readable',
	'file.unreadable'       => 'cannot read {file}: {error}',
	'producer.sets'         => "{file} sets '{key}'",
	'class.unavailable'     => '{class} is not available in this checkout',
	'class.compiles'        => '{class} compiles',
	'derivation.made'       => 'a {short} can still be made from {from}',
	'derivation.key'        => '{key} is derived',
	'consumer.offender'     => "{file} line {line} in {sub}() reads '{key}' ({kind}) - {why}",
	'consumer.clean'        => '{file} reads only keys every producer sets',
	'consumer.stale'        => "{sub}() reads '{key}' - {why}",
	'consumer.not_stale'    => '{file} still reads the keys it is allowed to rely on',
	'consumer.stale_advice' => 'Remove the stale entry, so the registry keeps describing the code.',
	'why.unpromised'        => 'no producer in this workspace ever sets it',
	'skip.siblings'         => 'sibling checkouts are not present ({missing})',
	'accessor.documented'   => '{accessor} is a documented accessor of {class}',
	'accessor.accounted'    => '{class} documents no accessor the contract accounts for nowhere',
	'accessor.drift'        => {
		one   => "{class} documents {names}, which this contract does not mention.\n"
			. "The value object and the reader contract have drifted apart.  For the\n"
			. "name above: list it in 'accessors' if a consumer may read it off a\n"
			. "result, in 'conditional' with the reason only some results carry it,\n"
			. "or in 'not_accessors' with the reason it is not a slot of one result.",
		other => "{class} documents {names}, which this contract does not mention.\n"
			. "The value object and the reader contract have drifted apart.  For each\n"
			. "name above: list it in 'accessors' if a consumer may read it off a\n"
			. "result, in 'conditional' with the reason only some results carry it,\n"
			. "or in 'not_accessors' with the reason it is not a slot of one result.",
	},
	'discovery.checked'     => 'found sources mentioning {source} ({count} checked)',
	'discovery.registered'  => 'the scanner found the registered consumer ({count} read a result)',
	'discovery.clean'       => 'no unregistered consumer reads a {source} result',
	'discovery.header'      => 'unregistered consumers of {source} results:',
	'discovery.advice'      => {
		one   => "Register it in 'consumers' (with its justification) or in 'ignored'\n"
			. '(with the reason it cannot receive one).',
		other => "Register each in 'consumers' (with its justification) or in 'ignored'\n"
			. '(with the reason it cannot receive one).',
	},
);

# The schema new() validates a declaration against; its keys are also the
# list of options new() knows.
Readonly::Hash my %SCHEMA => (
	dist_root           => { type => 'string', optional => 1 },
	workspace           => { type => 'string', optional => 1 },
	include             => { type => 'arrayref', optional => 1 },
	source              => { type => 'string', min => 1 },
	value_object        => { type => 'hashref', optional => 1 },
	guaranteed          => { type => 'arrayref' },
	conditional         => { type => 'hashref', optional => 1 },
	producers           => { type => 'hashref', optional => 1 },
	workspace_producers => { type => 'hashref', optional => 1 },
	consumers           => { type => 'hashref', optional => 1 },
	ignored             => { type => 'arrayref', optional => 1 },
	accessors           => { type => 'arrayref', optional => 1 },
	not_accessors       => { type => 'hashref', optional => 1 },
	inspection          => { type => 'arrayref', optional => 1 },
	methods             => { type => 'arrayref' },
	batch_methods       => { type => 'arrayref', optional => 1 },
	list_methods        => { type => 'arrayref', optional => 1 },
	own_consumers       => { type => 'boolean', optional => 1 },
	require_workspace   => { type => 'arrayref', optional => 1 },
	messages            => { type => 'hashref', optional => 1 },
);

# What the scanner does beyond reading a file, one name per rule, with the sub
# each rule is exercised through.  A mutation of that sub puts the rule back the
# way it was before it was written, and t/contract.t does that for every name in
# this list: each rule has a mutation subtest, and a rule with no mutation - or a
# mutation for a rule that is not here - fails the test.
#
# The list is part of the module because it has to move with it.  Its seam is
# named rather than the whole of the rule's implementation, because that is the
# one place a mutation has to reach: everything else follows from it.
Readonly::Hash my %SCANNER_RULE_SEAM => (
	shebang_programs   => '_program',
	batch_methods      => '_batch_methods_re',
	batch_selection    => '_selection_re',
	batch_value_sinks  => '_batch_value_sinks',
	list_methods       => '_list_methods_re',
	invocant_parameter => '_sub_ranges',
	accessor_reads     => '_accessor_read',
	accessor_headings  => 'documented_accessors',
	qualified_calls    => '_alternation',
	code_not_prose     => 'strip',
	own_consumers      => 'new',
);

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

=encoding utf8

=head1 METHODS

=head2 new

    my $contract = Test::Consumer::Contract->new(%declaration);

=head3 Purpose

Builds a contract from a declaration, validating it before any check runs.

=head3 Arguments

A list of pairs, or one hashref.  C<source>, C<guaranteed> and C<methods> are
required; every other option has a default.

=over 4

=item C<source> (string, required)

The name that marks a file as one that may consume results: a file that does
not contain it is not scanned during discovery.  Usually the producer's class.

=item C<guaranteed> (arrayref, required)

The keys every producer sets on every result.  A read of one of these is
always safe.

=item C<methods> (arrayref, required)

The calls that hand a result to the caller, as your producer spells them:
C<[qw(geocode reverse_geocode)]> for a geocoder, C<[qw(fetch find)]> for a
store.  There is no default: the checker cannot guess what your producer calls
its lookups, and a name it guessed would quietly find nothing.  A name may be
written with its class, C<< 'Widget->new' >> or C<'Widget::new'>, and then only
that class's call matches.  A variable bound from one of these is followed, as
is a variable passed to a sub that this file calls with it.

=item C<batch_methods> (arrayref)

The producing methods that return a batch of results rather than one result;
none by default.  A batch's keys are the results, plus counts about the batch
itself, so a variable bound from a batch method is not treated as a result -
C<< $batch->{'lookups'} >> is not a read of one - while
C<< my $point = $batch->{$value} >> makes C<$point> a result.

=item C<list_methods> (arrayref)

The producing methods that hand back a list of results rather than one - a
report's C<results()>, the checks a runner ran; none by default.  The variable
that takes a result out of the list is a result like any other: the loop
variable of C<< for my $entry (@{ $report->results() }) >>, of a list assigned
from that call first, and the topic of a C<map> or C<grep> block over it.

=item C<value_object> (hashref)

C<< { class => 'Widget', from => {...}, derives => {...} } >>.  C<class> is
required when this is given and must be a module name.  C<from> is what an
object is built from for check 2, C<derives> the accessor => value pairs it
must then return.

=item C<conditional> (hashref)

Key => why it is not guaranteed, used in the failure messages and accepted by
check 4 as accounting for a documented accessor.

=item C<producers> (hashref)

Path => arrayref of keys the file must still set.  Paths are relative to
C<dist_root>, or absolute.

=item C<workspace_producers> (hashref)

Like C<producers>, but paths are relative to the workspace: producers in a
sibling distribution that this distribution's value object comes from.

=item C<consumers> (hashref)

Workspace-relative (or, for C<own_consumers>, C<dist_root>-relative) path =>
C<< { may_rely_on => { sub_name => { key => why } } } >>.  A read outside any
named sub is registered under the sub name C<(file scope)>.

=item C<ignored> (arrayref)

C<[prefix, reason]> pairs: a discovered file whose path starts with the prefix
is not a consumer.  Each rule must be an arrayref whose first element is the
prefix.

=item C<accessors> (arrayref)

Documented accessors a consumer may call on a result.

=item C<not_accessors> (hashref)

Documented accessors of the value object that are not a slot of one result -
the constructor, a class constant - as name => why, so that the accessor check
can be satisfied by saying what a name is instead of listing it as something a
consumer may read.  A name here that the value object does not document fails,
as an entry in C<accessors> would.

=item C<inspection> (arrayref)

Methods such as C<can>, C<isa> and C<DOES> that may be called on a result
without being a read of a field.

=item C<own_consumers> (boolean)

True when the distribution being checked is one of its own value object's
readers; false by default.  Its C<lib>, C<bin> and C<scripts> are then scanned
for consumers and discovered like a sibling's, but not its C<t/> and C<xt/>: its
tests are the proof of the value object rather than readers of it.  Its paths
are named relative to the distribution, the way a producer's are, so they still
point at the right file when the distribution is installed under a versioned
directory name.

=item C<dist_root> (string)

The distribution being checked.  Defaults to the parent of the directory
holding the running test file, falling back to the current directory when that
is not a distribution root.  When given, it must be an existing directory.

=item C<workspace> (string)

The directory holding the sibling distributions.  Defaults to the parent of
C<dist_root>.  When given, it must be an existing directory.

=item C<include> (arrayref)

Workspace-relative lib directories to put at the front of C<@INC>, so a value
object is read from the checkout in the workspace rather than from an
installed copy.

=item C<require_workspace> (arrayref)

Sibling distribution names that must exist for checks 3 and 5 to run.  Pass the
ones your consumers live in, or those checks cannot tell a missing checkout
from a passing one.

=item C<messages> (hashref)

Message key => template, overriding the catalogue for this object only.  See
L</i18n>.

=back

Every path in a declaration is written with C</> between the directories,
whatever separator the platform itself uses, and the checks name files the
same way, so a path can be copied from a failure message into the declaration.

=head3 Returns

The new object.

=head3 Side Effects

Each existing C<include> directory is moved to the front of C<@INC> (through
L<lib>, so it appears there once however many contracts name it); the last one
listed ends up first.  C<@INC> is process-wide: the change outlives the
object.

=head3 EXAMPLE

    my $contract = Test::Consumer::Contract->new({
        source      => 'Warehouse::Stock',
        methods     => [qw(fetch scan)],
        guaranteed  => [qw(grams name)],
        conditional => { bin => 'only scan() knows the bin' },
    });

=head3 API SPECIFICATION

=head4 Input

    {
        source              => { type => 'string', min => 1 },
        guaranteed          => { type => 'arrayref' },
        methods             => { type => 'arrayref' },
        dist_root           => { type => 'string', optional => 1 },
        workspace           => { type => 'string', optional => 1 },
        include             => { type => 'arrayref', optional => 1 },
        value_object        => { type => 'hashref', optional => 1 },
        conditional         => { type => 'hashref', optional => 1 },
        producers           => { type => 'hashref', optional => 1 },
        workspace_producers => { type => 'hashref', optional => 1 },
        consumers           => { type => 'hashref', optional => 1 },
        ignored             => { type => 'arrayref', optional => 1 },
        accessors           => { type => 'arrayref', optional => 1 },
        not_accessors       => { type => 'hashref', optional => 1 },
        inspection          => { type => 'arrayref', optional => 1 },
        batch_methods       => { type => 'arrayref', optional => 1 },
        list_methods        => { type => 'arrayref', optional => 1 },
        own_consumers       => { type => 'boolean', optional => 1 },
        require_workspace   => { type => 'arrayref', optional => 1 },
        messages            => { type => 'hashref', optional => 1 },
    }

=head4 Output

    { type => 'object', isa => 'Test::Consumer::Contract' }

=head3 MESSAGES

    Message                                         Meaning / Resolution
    ----------------------------------------------  ----------------------------------------
    "...::new() does not know the option(s): X"     An option is misspelt or unknown.  Fix
                                                    the name; nothing is silently ignored.
    "...::new() needs a 'X'"                        A required option is missing or undef.
    "...::new(): <validator message>"               An option has the wrong type, for
                                                    example a string where an arrayref is
                                                    expected.
    "...::new(): each 'ignored' rule must be        An 'ignored' entry is not an arrayref
     [prefix, reason], not X"                       starting with a prefix.  Write
                                                    ['Dist/', 'why'].
    "...::new(): consumer 'X' must be {...}"        A consumers entry is not a hashref, or
                                                    its may_rely_on is not sub => {key=>why}.
    "...::new(): value_object needs a 'class'       value_object without a valid module name
     that is a module name, not 'X'"                in 'class'.
    "...::new(): dist_root 'X' is not a             An explicit dist_root or workspace does
     directory: <OS error>"                         not exist; the OS error says why.

=head3 FORMAL SPECIFICATION

    ┌─ New ─────────────────────────────────────────────────────
    │ spec? : OPTION ⇸ VALUE
    │ contract! : CONTRACT
    ├───────────────────────────────────────────────────────────
    │ dom spec? ⊆ KNOWN_OPTIONS
    │ {source, guaranteed, methods} ⊆ dom spec?
    │ ∀ o : dom spec? • spec?(o) ∈ TYPE(o)
    │ ∀ d : {dist_root, workspace} ∩ dom spec? • spec?(d) ∈ DIRECTORY
    │ contract!.options = DEFAULTS ⊕ spec?
    │ INC' = rev(includes(spec?)) ⁀ (INC ∖ ran includes(spec?))
    └───────────────────────────────────────────────────────────

=head3 PSEUDOCODE

    normalise the arguments into one hash
    croak on any option outside the schema
    croak on any required option that is undef
    validate the types; croak with the validator's reason on failure
    croak on malformed ignored rules, consumer entries or value_object class
    croak on an explicit dist_root or workspace that is not a directory
    fill in defaults, take a copy of %config
    put the include directories at the front of @INC
    return the object

=cut

sub new
{
	my $class = shift;

	# Params::Get accepts a list of pairs or one hashref, so a declaration can
	# be written either way.  An odd-length list is its error to report.
	my $spec = eval { get_params(undef, @_) } // {};
	$class->_croak('option.invalid', { error => _first_line($@) }) if($@);

	# A misspelt option fails before anything else: a declaration that quietly
	# ignored 'ignores' would pass for the wrong reason.
	my @unknown = grep { !exists($SCHEMA{$_}) } sort keys %{$spec};
	$class->_croak('option.unknown', { options => join(' ', @unknown) }) if(@unknown);

	# Checked here rather than by the validator, which accepts an undef value
	# for a required string and words the error its own way.
	foreach my $required (@REQUIRED) {
		$class->_croak('option.required', { option => $required }) unless(defined($spec->{$required}));
	}

	my $valid = eval { validate_strict(schema => \%SCHEMA, input => $spec) };
	$class->_croak('option.invalid', { error => _first_line($@) }) unless(defined($valid));

	$class->_assert_shapes($valid);

	# An explicit root that is not there is a mistake in the declaration; a
	# defaulted one is wherever the test is running, which always exists.
	foreach my $option (qw(dist_root workspace)) {
		$class->_assert_directory($option, $valid->{$option}) if(defined($valid->{$option}));
	}

	my $dist_root = $valid->{'dist_root'} // _default_dist_root();

	my $self = bless {
		%{_defaults()},
		%{$valid},
		dist_root     => $dist_root,
		dist_name     => basename($dist_root),
		workspace     => $valid->{'workspace'} // dirname($dist_root),
		own_consumers => $valid->{'own_consumers'} ? 1 : 0,
		config        => _config_snapshot(),
		_cache        => {},
	}, $class;

	return set_return($self->_include_workspace_libs(), { type => 'object' });
}

# _defaults
# Purpose      : The value of every optional option that was not given.
# Entry        : None.
# Exit status  : A new hashref each call, so no two objects share a list.
# Side effects : None.
sub _defaults :Private
{
	return {
		include             => [],
		value_object        => undef,
		conditional         => {},
		producers           => {},
		workspace_producers => {},
		consumers           => {},
		ignored             => [],
		accessors           => [],
		not_accessors       => {},
		inspection          => [],
		batch_methods       => [],
		list_methods        => [],
		require_workspace   => [],
		messages            => {},
	};
}

# _config_snapshot
# Purpose      : A copy of %config one level deep, taken when an object is built.
# Entry        : None.
# Exit status  : A new hashref of new arrayrefs/hashrefs.
# Side effects : None.  A later change to %config does not reach the object.
sub _config_snapshot :Private
{
	return { map {
		my $value = $config{$_};
		$_ => (ref($value) eq 'HASH') ? { %{$value} } : [ @{$value} ];
	} keys %config };
}

# _assert_shapes
# Purpose      : The structural checks the type schema cannot express: the
#                shape of each ignored rule, of each consumer entry, and the
#                value object's class name.
# Entry        : $spec -- the type-validated declaration.
# Exit status  : Returns the class; croaks on the first malformed entry.
# Side effects : None.
sub _assert_shapes :Private
{
	my ($class, $spec) = @_;

	# An 'ignored' rule written as a bare string used to be skipped without a
	# word, so the file it meant to ignore was reported as unregistered.
	foreach my $rule (@{$spec->{'ignored'} || []}) {
		$class->_croak('option.ignored', { rule => $rule // 'undef' })
			unless(ref($rule) eq 'ARRAY' && defined($rule->[0]) && !ref($rule->[0]));
	}

	# A consumer entry is dereferenced two levels deep during check 3; a wrong
	# shape there died with "Not a HASH reference" in the middle of a subtest.
	my $consumers = $spec->{'consumers'} || {};
	foreach my $consumer (sort keys %{$consumers}) {
		my $entry = $consumers->{$consumer};
		my $rely = (ref($entry) eq 'HASH') ? ($entry->{'may_rely_on'} // {}) : undef;
		my $ok = (ref($rely) eq 'HASH') && !grep { ref($_) ne 'HASH' } values %{$rely};
		$class->_croak('option.consumer', { consumer => $consumer }) unless($ok);
	}

	# The class is loaded by name, so only a module name is allowed: a path
	# fragment here would be handed to require.
	if(my $value_object = $spec->{'value_object'}) {
		my $name = $value_object->{'class'};
		$class->_croak('option.class', { class => $name // 'undef' })
			unless(defined($name) && is_module_name($name));
	}

	return $class;
}

# _assert_directory
# Purpose      : Croak, with the OS's own reason, when an option names a path
#                that cannot be opened as a directory.
# Entry        : $option -- the option name; $path -- its value.
# Exit status  : Returns the class when the directory opens; croaks otherwise.
# Side effects : Opens and closes the directory.
sub _assert_directory :Private
{
	my ($class, $option, $path) = @_;

	# opendir under autodie throws an exception that carries errno, so the
	# message says ENOENT or ENOTDIR in the words of the platform.
	my $opened = eval { opendir(my $dh, $path); closedir($dh); 1 };
	$class->_croak('option.directory', { option => $option, path => $path, error => _os_error($@) })
		unless($opened);

	return $class;
}

# _include_workspace_libs
# Purpose      : Put each existing 'include' directory at the front of @INC so
#                the value object is read from the workspace checkout.
# Entry        : An object whose workspace and include are set.
# Exit status  : Returns $self.
# Side effects : Changes @INC for the whole process.
sub _include_workspace_libs :Private
{
	my $self = shift;

	# lib->import removes a directory already in @INC before adding it again,
	# so building many contracts does not grow @INC without bound.  Reversed,
	# so the last one listed is first, as it always has been.
	my @dirs = grep { -d $_ }
		map { File::Spec->catdir($self->{'workspace'}, split(m{/}, $_)) } @{$self->{'include'}};
	lib->import(reverse @dirs) if(@dirs);

	return $self;
}

# _default_dist_root
# Purpose      : Find the distribution that the running test belongs to.
# Entry        : $0 is the running test, normally <dist>/t/<name>.t.
# Exit status  : An absolute directory path; the current directory when the
#                grandparent of $0 has no lib/.
# Side effects : None.
sub _default_dist_root :Private
{
	# abs_path() is undef for a $0 that is not a file, such as '-e'.
	my $script = abs_path($0);
	my $root = defined($script) ? dirname(dirname($script)) : undef;

	# Without a lib/ it is not a distribution, so fall back to where we are.
	$root = getcwd() unless(defined($root) && -d File::Spec->catdir($root, 'lib'));

	return $root;
}

=head2 run

    $contract->run();

=head3 Purpose

Runs the five checks described in L</DESCRIPTION>, each as a subtest.  Called
for you by C<run_consumer_contract()>.

=head3 Arguments

None.

=head3 Returns

The object, so calls can be chained.

=head3 Side Effects

Emits TAP through L<Test::Builder>.  Loads the value object's class.

=head3 EXAMPLE

    Test::Consumer::Contract->new(%declaration)->run();
    done_testing();

=head3 API SPECIFICATION

=head4 Input

    {}

=head4 Output

    { type => 'object', isa => 'Test::Consumer::Contract' }

=head3 MESSAGES

None of its own: each check's messages are listed in L</DIAGNOSTICS>.

=head3 FORMAL SPECIFICATION

    ┌─ Run ─────────────────────────────────────────────────────
    │ ΞCONTRACT
    │ tap! : seq SUBTEST
    ├───────────────────────────────────────────────────────────
    │ tap! = producers ⁀ derivation ⁀ consumers ⁀ accessors ⁀ discovery
    │ #tap! ≤ 5
    └───────────────────────────────────────────────────────────

=cut

sub run
{
	my $self = shift;

	# Each check decides for itself whether it applies, so the order here is
	# the whole of what run() knows about them.
	return set_return($self->_check_producers()->_check_derivation()->_check_consumers()
		->_check_accessors()->_check_discovery(), { type => 'object' });
}

=head2 run_consumer_contract

    my $contract = run_consumer_contract(%declaration);

=head3 Purpose

Builds the contract and runs it: C<< new(...)->run() >> as one exportable call.

=head3 Arguments

The declaration, as for L</new>.

=head3 Returns

The object.

=head3 Side Effects

Those of L</new> and L</run>.

=head3 EXAMPLE

    use Test::Most;
    use Test::Consumer::Contract qw(run_consumer_contract);

    run_consumer_contract(source => 'S', methods => ['fetch'], guaranteed => ['id']);
    done_testing();

=head3 API SPECIFICATION

=head4 Input

As for L</new>.

=head4 Output

    { type => 'object', isa => 'Test::Consumer::Contract' }

=head3 MESSAGES

Those of L</new>.

=head3 FORMAL SPECIFICATION

    RunConsumerContract ≙ New ⨾ Run

=cut

sub run_consumer_contract
{
	return set_return(__PACKAGE__->new(@_)->run(), { type => 'object' });
}

=head2 workspace_present

    if($contract->workspace_present()) { ... }

=head3 Purpose

Says whether every distribution named in C<require_workspace> is in the
workspace, which is what checks 3 and 5 need to run.

=head3 Arguments

None.

=head3 Returns

1 when every one is there, otherwise 0.

=head3 Side Effects

Caches the answer in the object.

=head3 EXAMPLE

    plan skip_all => 'no siblings' unless $contract->workspace_present();

=head3 API SPECIFICATION

=head4 Input

    {}

=head4 Output

    { type => 'boolean' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

    ┌─ WorkspacePresent ────────────────────────────────────────
    │ ΞCONTRACT
    │ present! : 𝔹
    ├───────────────────────────────────────────────────────────
    │ present! ⇔ ran require_workspace ⊆ dirs(workspace)
    └───────────────────────────────────────────────────────────

=cut

sub workspace_present
{
	my $self = shift;

	# Asked through the cache-filling method: the cache is only built when a
	# check first needs it, and reading the slot directly found nothing there.
	return set_return(@{$self->_missing_siblings()} ? 0 : 1, { type => 'boolean' });
}

# _missing_siblings
# Purpose      : The require_workspace distributions not in the workspace.
# Entry        : A constructed object.
# Exit status  : An arrayref of names, possibly empty.
# Side effects : Caches the arrayref in the object.
sub _missing_siblings :Private
{
	my $self = shift;

	return $self->{'_cache'}{'missing_siblings'} //= [
		grep { !-d File::Spec->catdir($self->{'workspace'}, $_) } @{$self->{'require_workspace'}}
	];
}

=head2 i18n

    my $text = $contract->i18n('check.producers');
    my $text = Test::Consumer::Contract->i18n('skip.siblings', { missing => 'X' });

=head3 Purpose

Turns a message key and its arguments into the text the user sees.  Every
diagnostic, test name and error this module produces goes through here, so all
of them can be reworded or translated.

=head3 Arguments

=over 4

=item C<$key> (string, required)

The message key, such as C<check.producers>.

=item C<\%args> (hashref)

The values for the template's placeholders.  C<{name}> is replaced by the
value; C<{name:%.2f}> formats it with that C<sprintf> conversion (only the
conversions C<s d f g e E x X o b u>, with their flags, are honoured).  An
arrayref value is joined with C<, >.  A placeholder with no value is left as
written, so a missing argument shows rather than vanishes.  C<package>
defaults to this module's name.

When the template is a hash of forms, C<context> picks one by name (a gender,
say), and otherwise C<count> picks C<zero> (if present), C<one> or C<other>.

=back

The template is looked up in the object's C<messages> option, then in
C<$config{messages}>, then in the built-in catalogue.

=head3 Returns

The message text.

=head3 Side Effects

None.

=head3 EXAMPLE

    local $Test::Consumer::Contract::config{'messages'}{'check.producers'}
        = 'die Erzeuger setzen noch die zugesagten Schluessel';

    my $contract = Test::Consumer::Contract->new(%declaration, messages => {
        'skip.siblings' => { one => 'missing: {missing}', other => 'missing ({count}): {missing}' },
    });

    print $contract->i18n('skip.siblings', { missing => 'A, B', count => 2 });
    # missing (2): A, B

=head3 API SPECIFICATION

=head4 Input

    {
        key  => { type => 'string', min => 1, position => 0 },
        args => { type => 'hashref', optional => 1, position => 1 },
    }

=head4 Output

    { type => 'string' }

=head3 MESSAGES

    Message                          Meaning / Resolution
    -------------------------------  ---------------------------------------------
    "no message called 'X'"          The key is in no catalogue.  This is a
                                     programming error and is raised with confess,
                                     so the stack trace shows the caller.
    "...::i18n() needs a 'key'"      The key is missing or undef.

=head3 FORMAL SPECIFICATION

    ┌─ I18n ────────────────────────────────────────────────────
    │ key? : KEY
    │ args? : NAME ⇸ VALUE
    │ text! : seq CHAR
    ├───────────────────────────────────────────────────────────
    │ catalogue = BUILTIN ⊕ config.messages ⊕ self.messages
    │ key? ∈ dom catalogue
    │ text! = interpolate(choose(catalogue(key?), args?), {package ↦ PACKAGE} ⊕ args?)
    └───────────────────────────────────────────────────────────

=head3 PSEUDOCODE

    validate the key and the arguments
    add package => this module's name under the caller's arguments
    take the first template defined in: object messages, %config messages, built-in
    confess if there is none
    if the template is a hash of forms, choose one by context, else by count
    replace each {name} or {name:%fmt} that has a value; leave the rest
    return the text

=cut

sub i18n
{
	my $self = shift;
	my $params = $self->_arguments('i18n', [qw(key args)],
		{ key => { type => 'string', min => 1 }, args => { type => 'hashref', optional => 1 } }, @_);

	my $key = $params->{'key'};
	my %args = (package => __PACKAGE__, %{$params->{'args'} || {}});

	# The object's own wording first, then the configured, then the built-in.
	my $entry = first { defined($_) }
		(ref($self) ? $self->{'messages'}{$key} : undef), $config{'messages'}{$key}, $MESSAGES{$key};

	# Not through _croak: an unknown key here would recurse.  confess, because
	# a missing key is the module's own bug and the stack is what finds it.
	confess(_interpolate($MESSAGES{'i18n.unknown'}, { key => $key })) unless(defined($entry));

	$entry = _choose_form($entry, \%args) if(ref($entry) eq 'HASH');

	return set_return(_interpolate($entry, \%args), { type => 'string' });
}

# _choose_form
# Purpose      : Pick one template out of a hash of forms.
# Entry        : $forms -- { context_or_plural_form => template };
#                $args -- the message arguments ('context', 'count').
# Exit status  : A template string ('' when the hash has no usable form).
# Side effects : None.
sub _choose_form :Private
{
	my ($forms, $args) = @_;

	my ($context, $count) = @{$args}{qw(context count)};

	# A named context (a gender, a register) wins over the count; the count
	# picks the plural form, with 'zero' optional and 'other' the fallback.
	my $form = (defined($context) && exists($forms->{$context})) ? $context
		: !looks_like_number($count)                         ? 'other'
		: ($count == 0 && exists($forms->{'zero'}))          ? 'zero'
		: ($count == 1)                                      ? 'one'
		:                                                      'other';

	return $forms->{$form} // $forms->{'other'} // '';
}

# _interpolate
# Purpose      : Replace each placeholder in a template with its argument.
# Entry        : $template -- a string; $args -- name => value.
# Exit status  : The text, with unknown placeholders left as written.
# Side effects : None.
sub _interpolate :Private
{
	my ($template, $args) = @_;

	# /p gives ${^MATCH}, which puts an unmatched placeholder back exactly as it
	# was written, without the global cost $& has on older perls.
	(my $text = $template) =~ s{$PLACEHOLDER}{
		exists($args->{$1}) ? _format_value($args->{$1}, $2) : ${^MATCH}
	}gep;

	return $text;
}

# _format_value
# Purpose      : Render one placeholder's value.
# Entry        : $value -- scalar, arrayref or undef; $format -- a sprintf
#                conversion, or undef.
# Exit status  : A string; undef renders as ''.
# Side effects : None.  'numeric' warnings are off: a %d given text renders 0
#                rather than shouting in the middle of a diagnostic.
sub _format_value :Private
{
	my ($value, $format) = @_;

	no warnings 'numeric';
	my $text = !defined($value)        ? ''
		: (ref($value) eq 'ARRAY') ? join(', ', @{$value})
		: defined($format)         ? sprintf($format, $value)
		:                            $value;

	return $text;
}

# _croak
# Purpose      : Raise an error whose text comes from the catalogue.
# Entry        : $key -- message key; $args -- its arguments.
# Exit status  : Does not return.
# Side effects : Croaks, from the perspective of the caller outside this module.
sub _croak :Private
{
	my ($self, $key, $args) = @_;

	croak($self->i18n($key, $args));
}

# _arguments
# Purpose      : Normalise a public method's arguments with Params::Get and
#                check them with Params::Validate::Strict, in one place.
# Entry        : $routine -- name for messages; $names -- positional names;
#                $schema -- the input schema; @args -- the caller's arguments.
# Exit status  : The validated hashref; croaks through the catalogue on failure.
# Side effects : None.
sub _arguments :Private
{
	my ($self, $routine, $names, $schema, @args) = @_;

	my $params = eval { get_params($names, @args) } // {};

	# A missing argument is named before the types are checked, in the
	# catalogue's words: the validator lets some undefs through and words the
	# others its own way.
	foreach my $name (grep { !$schema->{$_}{'optional'} } sort keys %{$schema}) {
		$self->_croak('argument.missing', { routine => $routine, argument => $name })
			unless(defined($params->{$name}));
	}

	my $valid = eval { validate_strict(schema => $schema, input => $params) };
	$self->_croak('argument.invalid', { routine => $routine, error => _first_line($@) }) unless(defined($valid));

	return $valid;
}

# _first_line
# Purpose      : The first line of an error, without Perl's " at FILE line N."
# Entry        : $error -- an exception (string or object) or undef.
# Exit status  : A string, possibly empty.
# Side effects : None.
sub _first_line :Private
{
	my ($line) = split(/\n/, defined($_[0]) ? "$_[0]" : '');
	$line //= '';
	$line =~ s/ at \S+ line \d+\.?\z//;

	return $line;
}

# _os_error
# Purpose      : The operating system's text for the error behind an exception.
# Entry        : $exception -- an autodie::exception, or any other error.
# Exit status  : The errno string as Perl renders "$!", else the first line.
# Side effects : None.
sub _os_error :Private
{
	my $exception = shift;

	return (blessed($exception) && $exception->can('errno')) ? $exception->errno : _first_line($exception);
}

# ---------------------------------------------------------------------------
# Reading source
# ---------------------------------------------------------------------------

# _read_source
# Purpose      : Read a whole file without dying.
# Entry        : $path -- a path.
# Exit status  : { text => content } on success, { error => OS error } otherwise.
# Side effects : Opens and closes the file.
sub _read_source :Private
{
	my (undef, $path) = @_;

	my %result;

	# autodie's exception keeps errno apart from the sentence around it, which
	# the i18n message needs; File::Slurper would fold both into English.
	my $read = eval {
		open(my $fh, '<', $path);
		local $/;
		$result{'text'} = <$fh>;
		close($fh);
		1;
	};
	$result{'error'} = _os_error($@) unless($read);

	return \%result;
}

# _readable
# Purpose      : Read a file the check depends on, asserting that it could be.
# Entry        : $path -- where it is; $label -- how the contract names it.
# Exit status  : The content, or undef when it could not be read.
# Side effects : Emits one ok(), and a diag() with the OS error on failure.
sub _readable :Private
{
	my ($self, $path, $label) = @_;

	my $source = $self->_read_source($path);

	ok(defined($source->{'text'}), $self->i18n('file.readable', { file => $label }))
		or diag($self->i18n('file.unreadable', { file => $label, error => $source->{'error'} }));

	return $source->{'text'};
}

=head2 sets_key

    $contract->sets_key($source_text, 'database')

=head3 Purpose

Says whether the text assigns the key, in any of the spellings a producer might
use: C<< key => value >>, C<< 'key' => value >>, C<< $obj->{'key'} = value >>,
C<< $obj->{'key'} ||= value >> and C<< $obj->{'key'} //= value >>.

=head3 Arguments

=over 4

=item C<$text> (string, required) - source, normally passed through L</strip>.

=item C<$key> (string, required) - the key.

=back

=head3 Returns

1 or 0.

=head3 Side Effects

None.

=head3 EXAMPLE

    my $text = $contract->strip($source);
    ok($contract->sets_key($text, 'colour'), 'the producer still sets colour');

=head3 API SPECIFICATION

=head4 Input

    {
        text => { type => 'string', position => 0 },
        key  => { type => 'string', min => 1, position => 1 },
    }

=head4 Output

    { type => 'boolean' }

=head3 MESSAGES

    Message                                      Meaning / Resolution
    -------------------------------------------  ----------------------------------
    "...::sets_key(): <validator message>"       An argument has the wrong type.
    "...::sets_key() needs a 'X'"                An argument is missing or undef.

=head3 FORMAL SPECIFICATION

    ┌─ SetsKey ─────────────────────────────────────────────────
    │ text? : seq CHAR
    │ key? : seq₁ CHAR
    │ sets! : 𝔹
    ├───────────────────────────────────────────────────────────
    │ sets! ⇔ (∃ q : {ε, ', "} • q⁀key?⁀q⁀"=>" in text?)
    │       ∨ (∃ q : {ε, ', "}; op : {"=", "||=", "//="} •
    │             "->{"⁀q⁀key?⁀q⁀"}"⁀op in text?)
    │ -- "==" and "=~" are comparisons, not assignments
    └───────────────────────────────────────────────────────────

=cut

sub sets_key
{
	my $self = shift;
	my $params = $self->_arguments('sets_key', [qw(text key)],
		{ text => { type => 'string' }, key => { type => 'string', min => 1 } }, @_);

	my ($text, $k) = ($params->{'text'}, quotemeta($params->{'key'}));

	# 'key' => value (the quotes must match) / key => value / ->{key} = value.
	# '==' and '=~' compare the key's value; neither sets it.
	my $sets = ($text =~ /(['"])$k\1\s*=>/)
		|| ($text =~ /(?:^|[\s(,{])$k\s*=>/m)
		|| ($text =~ /->\s*\{\s*(['"]?)$k\1\s*\}\s*(?:=(?![=~])|\|\|=|\/\/=)/);

	return set_return($sets ? 1 : 0, { type => 'boolean' });
}

# _producer_evidence
# Purpose      : Every producer the declaration names, with its path resolved.
# Entry        : A constructed object.
# Exit status  : An arrayref of { path, label, keys }, sorted by path.
# Side effects : None.
sub _producer_evidence :Private
{
	my $self = shift;

	my @evidence;

	# Dist-relative (or absolute) producers, then workspace-relative ones.  The
	# label is the path as the declaration spells it, for readable messages.
	foreach my $file (keys %{$self->{'producers'}}) {
		my $path = File::Spec->file_name_is_absolute($file)
			? $file
			: File::Spec->catfile($self->{'dist_root'}, split(m{/}, $file));
		push @evidence, { path => $path, label => $file, keys => $self->{'producers'}{$file} };
	}
	foreach my $file (keys %{$self->{'workspace_producers'}}) {
		push @evidence, {
			path  => File::Spec->catfile($self->{'workspace'}, split(m{/}, $file)),
			label => $file,
			keys  => $self->{'workspace_producers'}{$file},
		};
	}

	return [ sort { $a->{'path'} cmp $b->{'path'} } @evidence ];
}

# _check_producers
# Purpose      : Check 1: each producer still sets each key it is named for.
# Entry        : A constructed object.
# Exit status  : Returns $self.
# Side effects : One subtest, unless no producer is declared.
sub _check_producers :Protected
{
	my $self = shift;

	my $evidence = $self->_producer_evidence();

	if(@{$evidence}) {
		subtest $self->i18n('check.producers') => sub {
			foreach my $producer (@{$evidence}) {
				my $raw = $self->_readable($producer->{'path'}, $producer->{'label'});
				next unless(defined($raw));

				# The evidence is the code: a key in a POD example or a comment
				# documents the promise, it does not keep it.
				my $text = $self->strip($raw);

				foreach my $key (@{$producer->{'keys'}}) {
					ok($self->sets_key($text, $key),
						$self->i18n('producer.sets', { file => $producer->{'label'}, key => $key }));
				}
			}
		};
	}

	return $self;
}

# ---------------------------------------------------------------------------
# The value object
# ---------------------------------------------------------------------------

# _load_class
# Purpose      : Load the value object's class, telling "not installed" apart
#                from "installed but broken".
# Entry        : $class -- a module name (validated by new()).
# Exit status  : {} when loaded; { missing => 1 } when its file is not in
#                @INC; { error => text } when it is there but fails to load.
# Side effects : Loads the class; caches the answer in the object.
sub _load_class :Private
{
	my ($self, $class) = @_;

	return $self->{'_cache'}{'class'}{$class} //= do {
		my $loaded = eval { require_module($class); 1 };
		my $error = $@;
		my $file = module_notional_filename($class);

		# Only a failure to find the class's own file means it is absent; a
		# syntax error, or a dependency it cannot find, means it is broken.
		$loaded                                                   ? {}
			: ($error =~ /\ACan't locate \Q$file\E in \@INC/) ? { missing => 1 }
			:                                                   { error => _first_line($error) };
	};
}

# _class_ready
# Purpose      : Start a value-object subtest: skip it when the class is not
#                in this checkout, fail it when the class is broken.
# Entry        : Called first inside a subtest, before any assertion.
# Exit status  : True when the class is loaded, false when the subtest should
#                stop.
# Side effects : May plan skip_all (which leaves the subtest), or emit one
#                assertion (and a diag() when it fails).
sub _class_ready :Private
{
	my ($self, $class) = @_;

	my $state = $self->_load_class($class);

	plan(skip_all => $self->i18n('class.unavailable', { class => $class })) if($state->{'missing'});

	# Skipping a class that does not compile used to hide the breakage: the
	# check passed precisely when the value object was most wrong.
	my $ready = ok(!defined($state->{'error'}), $self->i18n('class.compiles', { class => $class }));
	diag($state->{'error'}) unless($ready);

	return $ready;
}

# _check_derivation
# Purpose      : Check 2: the value object still derives what it promises.
# Entry        : A constructed object.
# Exit status  : Returns $self.
# Side effects : One subtest when value_object has 'derives'; loads the class
#                and calls its constructor and accessors.
sub _check_derivation :Protected
{
	my $self = shift;

	my $spec = $self->{'value_object'} || {};
	my $derives = $spec->{'derives'} || {};

	return $self unless(%{$derives});

	my $class = $spec->{'class'};
	my $from = $spec->{'from'} || {};
	(my $short = lc($class)) =~ s/.*:://;

	subtest $self->i18n('check.derivation', { class => $class, keys => _list(sort keys %{$derives}) }) => sub {
		$self->_class_ready($class) or return;

		# A constructor that dies used to end the whole test file.  The error is
		# kept at once: i18n() validates its arguments in an eval of its own,
		# which resets $@ before the diagnostic could read it.
		my $object = eval { $class->new(%{$from}) };
		my $error = $@;
		ok($object, $self->i18n('derivation.made', { short => $short, from => join('/', sort keys %{$from}) }))
			or return diag(_first_line($error));

		foreach my $key (sort keys %{$derives}) {
			is(scalar(eval { $object->$key() }), $derives->{$key}, $self->i18n('derivation.key', { key => $key }));
		}
	};

	return $self;
}

# _list
# Purpose      : A list in prose: 'a', 'a and b', 'a, b and c'.
# Entry        : @items -- strings.
# Exit status  : A string; '' for no items.
# Side effects : None.  The conjunction comes from the 'list.and' message.
sub _list :Private
{
	my @items = @_;

	my $last = pop(@items);

	return !defined($last) ? ''
		: !@items      ? $last
		:                __PACKAGE__->i18n('list.and', { head => join(', ', @items), last => $last });
}

# ---------------------------------------------------------------------------
# Reading a consumer
# ---------------------------------------------------------------------------

=head2 strip

    my $code = $contract->strip($source);

=head3 Purpose

Removes what is not code, so that prose about a key is not mistaken for a use
of it: POD (to its C<=cut>, or to the end of the file when it has none),
whole-line comments, and everything after C<__END__> or C<__DATA__>.

=head3 Arguments

=over 4

=item C<$text> (string, required) - Perl source.

=back

=head3 Returns

The source with POD and comments blanked.  The lines are kept, so a line
number found in the result is the line number in the file.

=head3 Side Effects

None.

=head3 EXAMPLE

    my $code = $contract->strip("=head1 X\n\n\$w->{'pod'}\n\n=cut\nmy \$x = 1;\n");
    # "\n\n\n\n\nmy \$x = 1;\n"

=head3 API SPECIFICATION

=head4 Input

    { text => { type => 'string', position => 0 } }

=head4 Output

    { type => 'string' }

=head3 MESSAGES

    Message                                      Meaning / Resolution
    -------------------------------------------  ----------------------------------
    "...::strip() needs a 'text'"                The text is missing or undef.

=head3 FORMAL SPECIFICATION

    ┌─ Strip ───────────────────────────────────────────────────
    │ text?, code! : seq CHAR
    ├───────────────────────────────────────────────────────────
    │ let n == #lines(text? before __END__/__DATA__)
    │ #lines(code!) = n
    │ ∀ i : 1 ‥ n • lines(code!)(i) ∈ {ε, lines(text?)(i)}
    │ ∀ i : pod(text?) ∪ comments(text?) • lines(code!)(i) = ε
    └───────────────────────────────────────────────────────────

=cut

sub strip
{
	my $self = shift;
	my $text = $self->_arguments('strip', ['text'], { text => { type => 'string' } }, @_)->{'text'};

	# POD runs from a command paragraph to =cut, or to the end of the file when
	# it is never closed - common after __END__.  Only its newlines are kept.
	$text =~ s{(^=[a-zA-Z].*?(?:^=cut\b[^\n]*|\z))}{ (my $pod = $1) =~ tr/\n//cd; $pod }gems;

	# After __END__ or __DATA__ nothing is code.  Truncating there does not
	# move any line before it.
	$text =~ s{^__(?:END|DATA)__\b.*\z}{}ms;

	# Whole-line comments only: a '#' later in a line may be in a string, a
	# regex or $#array, which a lexical scanner cannot tell apart.
	$text =~ s{^[ \t]*\#[^\n]*}{}gm;

	return set_return($text, { type => 'string' });
}

# _line_number
# Purpose      : The 1-based line that a position in the text is on.
# Entry        : $text -- the text; $pos -- an offset into it.
# Exit status  : A line number.
# Side effects : None.  Counts on a copy: a /g match here would move the
#                caller's pos().
sub _line_number :Private
{
	my ($text, $pos) = @_;

	my $prefix = substr($text, 0, $pos);

	return 1 + ($prefix =~ tr/\n//);
}

# ---------------------------------------------------------------------------
# The rules the scanner applies to source
# ---------------------------------------------------------------------------

=head2 scanner_capabilities

    my $seam = Test::Consumer::Contract->scanner_capabilities();
    my @rules = sort keys %{$seam};

=head3 Purpose

Every rule the scanner applies to source beyond reading the file, as rule name
=> the name of the sub the rule is exercised through.  C<shebang_programs> is
an extensionless program being a consumer; C<accessor_headings> is where a
value object documents an accessor; C<code_not_prose> is producer evidence
having to be code.  The list is here so that the tests and the code cannot
drift apart: C<t/contract.t> mutates each named sub back to its behaviour
before the rule existed, and fails when a rule here has no mutation subtest,
when a mutation names a rule that is not here, and when a row names a sub this
module does not define.  A rule therefore cannot be added without the test
that shows what it catches.

=head3 Arguments

None.  May be called on the class or an object.

=head3 Returns

A new hashref, in any context: a list of names where a hash of names to seams
was asked for would leave every seam undef.  The caller may change it freely.

=head3 Side Effects

None.

=head3 EXAMPLE

    my $seam = Test::Consumer::Contract->scanner_capabilities();
    print "$_ -> $seam->{$_}\n" for sort keys %{$seam};

=head3 API SPECIFICATION

=head4 Input

    {}

=head4 Output

    { type => 'hashref' }

=head3 MESSAGES

None.

=head3 FORMAL SPECIFICATION

    ┌─ ScannerCapabilities ─────────────────────────────────────
    │ seam! : RULE ⇸ SUBNAME
    ├───────────────────────────────────────────────────────────
    │ seam! = SCANNER_RULE_SEAM
    │ ran seam! ⊆ dom SUBS(Test::Consumer::Contract)
    └───────────────────────────────────────────────────────────

=cut

sub scanner_capabilities
{
	return set_return({ %SCANNER_RULE_SEAM }, { type => 'hashref' });
}

# _alternation
# Purpose      : One regex matching any of a list of producing calls.
# Entry        : $cache_key -- where to keep it; $names -- the calls, bare
#                ('fetch') or qualified ('Widget::Maker->fetch').
# Exit status  : A qr//.  With no names it is a pattern that never matches: an
#                empty alternation would match everywhere and make every '(' a
#                producing call.
# Side effects : Caches the regex in the object.
# Notes        : Bare names go longest first, so 'geocode' is not matched as
#                the prefix of 'geocode_many'.  A qualified name matches only
#                that class's call, written with '->' or '::'.  Both parts are
#                quotemeta'd here: a \Q that arrives by interpolation is not
#                honoured, so writing one would leave the class name unquoted.
sub _alternation :Private
{
	my ($self, $cache_key, $names) = @_;

	return $self->{'_cache'}{$cache_key} //= do {
		my @bare = sort { length($b) <=> length($a) } grep { !/$QUALIFIED_NAME/ } @{$names};
		my @qualified = map { [ /$QUALIFIED_NAME/ ] } grep { /$QUALIFIED_NAME/ } @{$names};

		my @calls = (
			(map { '->\s*' . quotemeta($_) } @bare),
			(map { '(?<![\w:])' . quotemeta($_->[0]) . '\s*(?:->|::)\s*' . quotemeta($_->[1]) } @qualified),
		);

		@calls ? qr/(?:@{[ join('|', @calls) ]})/ : $NEVER;
	};
}

# _methods_re
# Purpose      : The calls that hand one result to a variable.
# Entry/Exit   : A constructed object / a qr//.
# Side effects : Caches through _alternation.
sub _methods_re :Private
{
	my $self = shift;

	return $self->_alternation('methods_re', $self->{'methods'});
}

# _batch_methods_re
# Purpose      : The calls that hand a batch of results to a variable.
# Entry/Exit   : A constructed object / a qr//.
# Side effects : Caches through _alternation.
sub _batch_methods_re :Private
{
	my $self = shift;

	return $self->_alternation('batch_methods_re', $self->{'batch_methods'});
}

# _list_methods_re
# Purpose      : The calls that hand back a list of results.  The name alone
#                does not say which variable holds one: the shape of the read
#                does, and _bind_list_results() works that out.
# Entry/Exit   : A constructed object / a qr//.
# Side effects : Caches through _alternation.
sub _list_methods_re :Private
{
	my $self = shift;

	return $self->_alternation('list_methods_re', $self->{'list_methods'});
}

# _selection_re
# Purpose      : A value selected out of a batch: ->{$value}, ->{'London'}.
#                The selector is a word, or a variable holding one - $_
#                included, which is how a map over the batch is written.
# Entry/Exit   : None / a qr// with no capturing group.
# Side effects : None.
sub _selection_re :Private
{
	return qr/->\s*\{\s*(?:['"]?\w+['"]?|\$[A-Za-z_]\w*)\s*\}/;
}

# _accessor_read
# Purpose      : A read through an accessor: ->name, with or without its
#                parentheses.  $result->score and $result->score() are the
#                same read; insisting on the parentheses found nothing in a
#                reader written the first way.
# Entry/Exit   : None / a qr// capturing the accessor name in $1.
# Side effects : None.
sub _accessor_read :Private
{
	return qr/\s*->\s*(\w+)\s*(?:\(|\b)/;
}

# _block_end
# Purpose      : Where the block opened at $open closes, counting the braces of
#                anything nested inside it.
# Entry        : $text; $open -- the offset of a '{'.
# Exit status  : The offset of the matching '}', or undef if it never closes.
# Side effects : None (works on a copy, so the caller's pos() is untouched).
# Notes        : Text::Balanced also skips braces inside quoted strings, which
#                a bare depth count took for real ones.
sub _block_end :Private
{
	my ($text, $open) = @_;

	pos($text) = $open;
	my ($block) = extract_bracketed($text, $BLOCK_DELIMITERS);

	return (defined($block) && length($block)) ? $open + length($block) - 1 : undef;
}

# _sub_ranges
# Purpose      : Where each named sub starts and ends, and what it declares.
# Entry        : $text -- stripped source.
# Exit status  : An arrayref of { name, start, end, params }, in file order.
#                params lists the parameters in order, the invocant first when
#                it is declared 'my $self = shift'.
# Side effects : None.
# Notes        : A sub starts with 'sub NAME' in column 0.  One whose braces
#                close on the same line ends there; any other ends at the next
#                '}' in column 0.  Without the one-line case 'sub x { ... }'
#                ran on to the next sub's closing brace, and that sub was then
#                reported under the wrong name.  A forward declaration
#                ('sub x;') has no body and no range.
sub _sub_ranges :Private
{
	my (undef, $text) = @_;

	my @ranges;
	while($text =~ /^sub\s+(\w+)\b([^\n]*)/mg) {
		my ($name, $rest, $start) = ($1, $2, $-[0]);
		next if($rest =~ /\A\s*;/);

		# Balanced, non-zero braces on the 'sub' line are a one-line body.
		# Otherwise carry on from here to the closing brace in column 0.
		my $opens = ($rest =~ tr/{//);
		my $end = ($opens && $opens == ($rest =~ tr/}//)) ? $+[0]
			: ($text =~ /\G.*?^\}/msgc)               ? $+[0]
			:                                           undef;
		next unless(defined($end));

		push @ranges, {
			name   => $name,
			start  => $start,
			end    => $end,
			params => _declared_params(substr($text, $start, $end - $start)),
		};
	}

	return \@ranges;
}

# _declared_params
# Purpose      : The parameters a sub body declares, in order, so a caller's
#                argument can be matched to the parameter that receives it.
# Entry        : $body -- the text of one sub.
# Exit status  : An arrayref of variable names ('$self', '$result', ...).
# Side effects : None.
sub _declared_params :Private
{
	my $body = shift;

	# my ($self, $result) = @_;  - every list taken from @_, in order.
	my @params;
	while($body =~ /^\s*my\s*\(([^)]*)\)\s*=\s*\@_/mg) {
		push @params, ($1 =~ /(\$[A-Za-z_]\w*)/g);
	}

	# my $self = shift;  - the invocant, declared without a list.  Any other
	# first 'my' is taken as the single parameter of a function.
	if($body =~ /^\s*my\s+(\$[A-Za-z_]\w*)\s*=\s*shift\b/m) {
		unshift @params, $1 if($1 eq '$self');
	} elsif(!@params && $body =~ /^\s*my\s+(\$[A-Za-z_]\w*)/m) {
		@params = ($1);
	}

	return \@params;
}

# _enclosing_sub
# Purpose      : The name of the sub a position falls in.
# Entry        : $ranges -- from _sub_ranges(); $pos -- an offset.
# Exit status  : The sub's name, or '(file scope)'.
# Side effects : None.
sub _enclosing_sub :Private
{
	my ($ranges, $pos) = @_;

	my $range = first { $pos >= $_->{'start'} && $pos < $_->{'end'} } @{$ranges};

	return $range ? $range->{'name'} : $FILE_SCOPE;
}

# _assigned_from
# Purpose      : The variables a statement assigns from an expression that
#                reaches $source_re: my $x = ... $maker->geocode(...
# Entry        : $text -- stripped source; $source_re -- what the right-hand
#                side must reach before the statement ends.
# Exit status  : An arrayref of variable names, in file order.
# Side effects : None.
sub _assigned_from :Private
{
	my ($text, $source_re) = @_;

	# The right-hand side stops at ';', '{' or '}', so a value in a later
	# statement or a block is never taken for this one's.
	my @names;
	push @names, $1 while($text =~ /$DECLARATOR($VARIABLE)$ASSIGNMENT[^;{}]*?$source_re/g);

	return \@names;
}

# _collect_reads
# Purpose      : Record each read of a result that a prefix leads to: the
#                ->{key} after it, and the ->accessor after it.
# Entry        : $text -- stripped source; $prefix -- a qr// for what holds a
#                result (it must not capture); $ranges -- from _sub_ranges();
#                $reads -- the arrayref to add to.
# Exit status  : Returns $reads.
# Side effects : Pushes [key, line, kind, sub] onto $reads.
sub _collect_reads :Private
{
	my ($text, $prefix, $ranges, $reads) = @_;

	# Every pass reports reads the same way, so one routine does it for all of
	# them.  _accessor_read() is asked each time because it is a seam.
	my %kinds = ($KIND_KEY => qr/$prefix$KEY_READ/, $KIND_ACCESSOR => qr/$prefix${\ _accessor_read()}/);

	foreach my $kind ($KIND_KEY, $KIND_ACCESSOR) {
		while($text =~ /$kinds{$kind}/g) {
			my $at = pos($text);
			push @{$reads}, [$1, _line_number($text, $at), $kind, _enclosing_sub($ranges, $at)];
		}
	}

	return $reads;
}

=head2 reads_of_results

    my @reads = $contract->reads_of_results($stripped_text);
    my $reads = $contract->reads_of_results($stripped_text);

=head3 Purpose

Finds every C<< ->{key} >> and C<< ->accessor >> read of a variable that holds
a result.  A variable holds one if it is bound from a call in C<methods>; if it
is the loop variable or topic over a call in C<list_methods>; if it is a value
taken out of a batch from a call in C<batch_methods>; if it is bound from a sub
that returns such a value; or if it is the parameter of a sub that this file
calls with a variable that already holds one (the second parameter, for a
method whose first is C<$self>).  A value out of a batch is a result wherever
it is put: into a variable, into a hash, or back out of a sub through a plain
C<return>.

=head3 Arguments

=over 4

=item C<$text> (string, required) - source, normally passed through L</strip>.

=back

=head3 Returns

In list context, the reads; in scalar context, an arrayref of them.  Each read
is C<[key, line, kind, sub]>: C<kind> is C<key> or C<accessor>, C<sub> is the
enclosing sub or C<(file scope)>.  They are in line order.

=head3 Side Effects

None.

=head3 EXAMPLE

    my $reads = $contract->reads_of_results($contract->strip(<<'CODE'));
    my $w = $maker->make(size => 2);
    return $w->{'colour'};
    CODE
    # [ ['colour', 2, 'key', '(file scope)'] ]

=head3 API SPECIFICATION

=head4 Input

    { text => { type => 'string', position => 0 } }

=head4 Output

    {
        type    => 'arrayref',
        element => { type => 'arrayref' },   # [key, line, kind, sub]
    }

=head3 MESSAGES

    Message                                      Meaning / Resolution
    -------------------------------------------  ----------------------------------
    "...::reads_of_results() needs a 'text'"     The text is missing or undef.

=head3 FORMAL SPECIFICATION

    ┌─ ReadsOfResults ──────────────────────────────────────────
    │ ΞCONTRACT
    │ text? : seq CHAR
    │ reads! : seq (KEY × ℕ₁ × KIND × SUBNAME)
    ├───────────────────────────────────────────────────────────
    │ holds = μ H : ℙ VAR | H = bound(text?) ∪ helpers(text?, H)
    │ ran reads! = { k, l, kind, s | (∃ v : holds ∖ batches(text?) •
    │                  read(text?, v, k, kind) at l in s) }
    │ ∀ i, j : dom reads! | i < j • line(reads!(i)) ≤ line(reads!(j))
    └───────────────────────────────────────────────────────────

=head3 PSEUDOCODE

    batches  := variables assigned from a batch method call
    bound    := variables assigned from a producing call, minus batches
    add the loop variables and topics over a list method's results
    add the variables assigned a value selected out of a batch
    sinks    := hashes holding batch values; subs returning one
    for each sub returning a batch value:
        add the variables assigned from a call to it
        record reads written straight off a call to it
    repeat until nothing new: add the parameter that receives a bound variable
    record reads off every bound variable
    record reads straight off a batch selection
    record reads through an element of a hash that holds results
    sort the reads by line

=cut

sub reads_of_results
{
	my $self = shift;
	my $text = $self->_arguments('reads_of_results', ['text'], { text => { type => 'string' } }, @_)->{'text'};

	my $ranges = $self->_sub_ranges($text);
	my $selection = _selection_re();

	# A batch - geocode_many() - is a hash of results with counts about the
	# batch beside them, so the variable is noted apart from the results.
	my %is_batch = map { $_ => 1 } @{_assigned_from($text, qr/${\ $self->_batch_methods_re()}\s*\(/)};

	my %bound = map { $_ => 1 } grep { !$is_batch{$_} }
		@{_assigned_from($text, qr/${\ $self->_methods_re()}\s*\(/)};

	$self->_bind_list_results($text, \%bound);

	# Into a variable: my $point = $batch->{$value};
	foreach my $batch_var (sort keys %is_batch) {
		$bound{$_} = 1 for grep { !$is_batch{$_} }
			@{_assigned_from($text, qr/\Q$batch_var\E\s*$selection/)};
	}

	# A value taken out of a batch can also go straight into a hash, or
	# straight back out of a sub.  Both are found in one place.
	my $sinks = $self->_batch_value_sinks($text, $ranges, \%is_batch);

	my @reads;

	# A sub that hands a result back is a source of them: a variable bound from
	# a call to it holds one - $self->pick(...) or pick(...) - and a read
	# written straight off the call is a read of one.
	foreach my $name (sort keys %{$sinks->{'hands_back'}}) {
		my $call = qr/(?<![\w:])\Q$name\E\s*\(/;
		$bound{$_} = 1 for grep { !$is_batch{$_} } @{_assigned_from($text, $call)};
		_collect_reads($text, qr/(?<![\w:])(?:->\s*)?\Q$name\E\s*\([^()]*\)/, $ranges, \@reads);
	}

	$self->_follow_helpers($text, $ranges, \%bound);

	foreach my $var (grep { !$is_batch{$_} } sort keys %bound) {
		_collect_reads($text, qr/\Q$var\E/, $ranges, \@reads);
	}

	# A value taken out of a batch and read there and then, with no variable
	# in between: in a hash literal, an argument or a returned expression.
	foreach my $batch_var (sort keys %is_batch) {
		_collect_reads($text, qr/\Q$batch_var\E\s*$selection/, $ranges, \@reads);
	}

	# Through an element of a hash that holds results.  A hash is declared with
	# its own sigil and read through a scalar's - my %points is read
	# $points{$key} - so the element is spelled with '$' however it was named.
	foreach my $var (sort keys %{$sinks->{'holds'}}) {
		my $name = substr($var, 1);
		_collect_reads($text,
			qr/\$\Q$name\E\s*(?:->)?\s*\{\s*(?:['"]?\w+['"]?|\$[A-Za-z_]\w*)\s*\}/, $ranges, \@reads);
	}

	# The passes run one shape at a time, so the reads are put back in the
	# order a person reads the file.  Perl's sort is stable, so ties keep the
	# order the passes found them in.
	@reads = sort { $a->[1] <=> $b->[1] } @reads;

	return wantarray ? @reads : set_return(\@reads, { type => 'arrayref' });
}

# _bind_list_results
# Purpose      : Mark the variables that take one result out of a list method:
#                the loop variable of a loop over the call, or over a list
#                assigned from it; the topic of a map or grep over it; and a
#                scalar assigned out of such a list.
# Entry        : $text -- stripped source; $bound -- the set to add to.
# Exit status  : Returns $self.
# Side effects : Adds names to %$bound.
sub _bind_list_results :Private
{
	my ($self, $text, $bound) = @_;

	my $list = $self->_list_methods_re();
	my $list_call = qr/\@\{\s*[^;{}]*?$list\s*\(?\s*\}/;

	my @lists;
	push @lists, quotemeta($1) while($text =~ /(?<![\w:])(?:my|our|local)\s*\@([A-Za-z_]\w*)\s*=\s*$list_call/g);

	$bound->{$1} = 1 while($text =~ /for\s+my\s+($VARIABLE)\s*\([^;]*?$list_call/g);

	# The block is found by balancing its braces rather than by matching to
	# the first '}': a map over results reads a key, and a key read has braces
	# of its own, so the first '}' can be the one inside $_->{'cents'}.
	while($text =~ /(?:map|grep)\s*\{/g) {
		my $close = _block_end($text, pos($text) - 1);
		next unless(defined($close) && substr($text, $close + 1) =~ /\A\s*$list_call/);
		$bound->{'$_'} = 1;
		last;
	}

	foreach my $name (@lists) {
		$bound->{$1} = 1 while($text =~ /for\s+my\s+($VARIABLE)\s*\(\s*\@$name\s*\)/g);
		$bound->{$1} = 1 while($text =~ /(?<![\w:])$DECLARATOR\(?\s*($VARIABLE)\s*\)?$ASSIGNMENT\@$name\b/g);
	}

	return $self;
}

# _follow_helpers
# Purpose      : Follow a result into the subs it is passed to, until nothing
#                new is found.
# Entry        : $text -- stripped source; $ranges -- from _sub_ranges();
#                $bound -- the variables known to hold a result.
# Exit status  : Returns $self.
# Side effects : Adds the receiving parameters to %$bound.
# Notes        : The receiving parameter is the first for a plain call and the
#                one after the invocant for a method whose first parameter is
#                $self: reading that as the first made $self a result, and
#                every $self->{...} in the file a read of one.
sub _follow_helpers :Private
{
	my ($self, $text, $ranges, $bound) = @_;

	my %declares = map { $_->{'name'} => $_->{'params'} } @{$ranges};

	# A fixed point: a parameter bound in one round may be passed on in the next.
	my $found = 1;
	while($found) {
		$found = 0;
		foreach my $name (grep { @{$declares{$_}} } sort keys %declares) {
			my @declare = @{$declares{$name}};
			foreach my $caller_var (sort keys %{$bound}) {
				my $index = _argument_index($text, $name, $caller_var, $declare[0]);
				next unless(defined($index) && defined($declare[$index]) && !$bound->{$declare[$index]});
				$bound->{$declare[$index]} = 1;
				$found = 1;
			}
		}
	}

	return $self;
}

# _argument_index
# Purpose      : Which of a sub's parameters receives a variable, if this file
#                passes the variable to it at all.
# Entry        : $text; $name -- the sub; $var -- the variable; $first -- the
#                sub's first declared parameter.
# Exit status  : 1 for $obj->name($var) when $first is $self, 0 for any other
#                call that passes $var first, undef when there is none.
# Side effects : None.
sub _argument_index :Private
{
	my ($text, $name, $var, $first) = @_;

	my ($n, $v) = (quotemeta($name), quotemeta($var));

	return ($text =~ /->\s*$n\s*\(\s*$v\b/)                                ? ((($first // '') eq '$self') ? 1 : 0)
		: ($text =~ /(?<![\w:>-])$n\s*\(\s*(?:\{\s*\w+\s*=>\s*)?$v\b/) ? 0
		:                                                                undef;
}

# _batch_value_sinks
# Purpose      : Where a value taken out of a batch goes when it does not go
#                into a variable of its own: into a hash, or back out of a sub.
# Entry        : $text; $ranges -- from _sub_ranges(); $is_batch -- the batch
#                variables.
# Exit status  : { holds => { '%name' or '$name' => 1 },
#                  hands_back => { sub_name => 1 } }.
# Side effects : None.
sub _batch_value_sinks :Private
{
	my ($self, $text, $ranges, $is_batch) = @_;

	my $selection = _selection_re();
	my (%holds, %hands_back);

	foreach my $batch_var (sort keys %{$is_batch}) {
		my $from_batch = qr/\Q$batch_var\E\s*$selection/;

		# Into an element: $points{$value} = $batch->{$value}.  The lookbehind
		# keeps $self->{'points'}{$value} - a hash held in a field - from
		# naming $self as the hash, which would make every read of $self one.
		$holds{$1} = 1 while($text =~ /(?<![\w\$>\]])([%\$][A-Za-z_]\w*)\s*(?:->\s*)?\{[^{}]*\}\s*=[^;]*?$from_batch/g);

		# Into a whole hash built around the batch: a map over its values, a
		# list of pairs, a hashref literal.  The statement ends at ';', so the
		# braces of those forms are crossed and nothing else is.
		$holds{$1} = 1 while($text =~ /$DECLARATOR([%\$][A-Za-z_]\w*)$ASSIGNMENT[^;]*?$from_batch/g);

		# Out of a sub: only a return that is nothing but the value counts -
		# 'return $batch->{$v} if $want' has another way out, and this scanner
		# does not follow a branch.
		foreach my $range (@{$ranges}) {
			my $body = substr($text, $range->{'start'}, $range->{'end'} - $range->{'start'});
			$hands_back{$range->{'name'}} = 1 if($body =~ /\breturn\s+$from_batch\s*;/);
		}
	}

	return { holds => \%holds, hands_back => \%hands_back };
}

# _why
# Purpose      : Why a key is not safe to read: its 'conditional' reason, or
#                the fact that no producer sets it.
# Entry/Exit   : $key / a string.
# Side effects : None.
sub _why :Private
{
	my ($self, $key) = @_;

	return exists($self->{'conditional'}{$key}) ? $self->{'conditional'}{$key} : $self->i18n('why.unpromised');
}

# ---------------------------------------------------------------------------
# CHECK 3 - registered consumers read only guaranteed keys
# ---------------------------------------------------------------------------

# _skip_without_siblings
# Purpose      : Skip a workspace subtest when a required sibling is absent.
# Entry        : Called first inside a subtest.
# Exit status  : Returns $self when every sibling is there.
# Side effects : plan skip_all, which leaves the subtest, when one is missing.
sub _skip_without_siblings :Private
{
	my $self = shift;

	my @missing = sort @{$self->_missing_siblings()};
	plan(skip_all => $self->i18n('skip.siblings', { missing => join(', ', @missing), count => scalar(@missing) }))
		if(@missing);

	return $self;
}

=head2 consumer_path

    my $path = $contract->consumer_path($relative);

=head3 Purpose

Where a registered consumer is, as a path on this platform.  A consumer in a
sibling distribution is named relative to C<workspace>; one in the
distribution being checked is named the way a producer is, relative to
C<dist_root>, because the directory a distribution is installed under is not
the name the contract spells.

=head3 Arguments

=over 4

=item C<$relative> (string, required) - the path as the contract spells it.

=back

=head3 Returns

The workspace path when a file is there, otherwise the C<dist_root> path
(whether or not that exists).

=head3 Side Effects

None.

=head3 EXAMPLE

    my $path = $contract->consumer_path('Widget-User/lib/Widget/User.pm');

=head3 API SPECIFICATION

=head4 Input

    { relative => { type => 'string', min => 1, position => 0 } }

=head4 Output

    { type => 'string' }

=head3 MESSAGES

    Message                                         Meaning / Resolution
    ----------------------------------------------  ----------------------------------
    "...::consumer_path() needs a 'relative'"       The path is missing or undef.

=head3 FORMAL SPECIFICATION

    ┌─ ConsumerPath ────────────────────────────────────────────
    │ ΞCONTRACT
    │ rel? : PATH
    │ path! : PATH
    ├───────────────────────────────────────────────────────────
    │ workspace ⁄ rel? ∈ FILES ⇒ path! = workspace ⁄ rel?
    │ workspace ⁄ rel? ∉ FILES ⇒ path! = dist_root ⁄ rel?
    └───────────────────────────────────────────────────────────

=cut

sub consumer_path
{
	my $self = shift;
	my $rel = $self->_arguments('consumer_path', ['relative'],
		{ relative => { type => 'string', min => 1 } }, @_)->{'relative'};

	my $path = File::Spec->catfile($self->{'workspace'}, split(m{/}, $rel));
	$path = File::Spec->catfile($self->{'dist_root'}, split(m{/}, $rel)) unless(-f $path);

	return set_return($path, { type => 'string' });
}

# _expect_none
# Purpose      : One assertion that a list is empty, with a readable
#                diagnostic when it is not.
# Entry        : $found -- arrayref; $name -- the test name; $lines -- the
#                diagnostic lines (default: the found items).
# Exit status  : The assertion's result.
# Side effects : One is_deeply(); a diag() on failure.
sub _expect_none :Private
{
	my ($self, $found, $name, $lines) = @_;

	my $ok = is_deeply($found, [], $name);
	diag($DIAG_INDENT . join($DIAG_INDENT, @{$lines // $found}) . "\n") unless($ok);

	return $ok;
}

# _check_consumers
# Purpose      : Check 3: every registered consumer reads only guaranteed
#                keys, and still reads every key it registered.
# Entry        : A constructed object.
# Exit status  : Returns $self.
# Side effects : One subtest when consumers are declared.
sub _check_consumers :Protected
{
	my $self = shift;

	my $consumers = $self->{'consumers'};

	if(%{$consumers}) {
		subtest $self->i18n('check.consumers') => sub {
			$self->_skip_without_siblings();

			foreach my $rel (sort keys %{$consumers}) {
				my $raw = $self->_readable($self->consumer_path($rel), $rel);
				next unless(defined($raw));

				$self->_check_one_consumer($rel, $consumers->{$rel}{'may_rely_on'} || {},
					scalar($self->reads_of_results($self->strip($raw))));
			}
		};
	}

	return $self;
}

# _check_one_consumer
# Purpose      : The two assertions check 3 makes about one consumer.
# Entry        : $rel -- the consumer as named; $may_rely_on -- its registry
#                entry; $reads -- from reads_of_results().
# Exit status  : Returns $self.
# Side effects : Two assertions.
sub _check_one_consumer :Private
{
	my ($self, $rel, $may_rely_on, $reads) = @_;

	# Built once: a grep over the lists for every read was quadratic.
	my %guaranteed = map { $_ => 1 } @{$self->{'guaranteed'}};
	my %callable = map { $_ => 1 } (@{$self->{'accessors'}}, @{$self->{'inspection'}});

	my (@offenders, %used);
	foreach my $read (@{$reads}) {
		my ($key, $line, $kind, $sub) = @{$read};
		$used{"$sub|$key"} = 1;

		next if($guaranteed{$key});
		next if($may_rely_on->{$sub} && exists($may_rely_on->{$sub}{$key}));
		next if($kind eq $KIND_ACCESSOR && $callable{$key});

		push @offenders, $self->i18n('consumer.offender',
			{ file => $rel, line => $line, sub => $sub, key => $key, kind => $kind, why => $self->_why($key) });
	}
	$self->_expect_none(\@offenders, $self->i18n('consumer.clean', { file => $rel }));

	# A registry entry nothing reads any more no longer describes the code.
	my @stale;
	foreach my $sub (sort keys %{$may_rely_on}) {
		push @stale, map { $self->i18n('consumer.stale', { sub => $sub, key => $_, why => $may_rely_on->{$sub}{$_} }) }
			grep { !$used{"$sub|$_"} } sort keys %{$may_rely_on->{$sub}};
	}
	$self->_expect_none(\@stale, $self->i18n('consumer.not_stale', { file => $rel }),
		[ @stale, $self->i18n('consumer.stale_advice') ]);

	return $self;
}

# ---------------------------------------------------------------------------
# CHECK 5 - no unregistered consumer
# ---------------------------------------------------------------------------

# _children
# Purpose      : The visible entries of a directory.
# Entry        : $dir -- a directory path.
# Exit status  : An arrayref of names (no '.', '..' or dot-files); empty when
#                the directory cannot be opened.
# Side effects : Opens and closes the directory.
sub _children :Private
{
	my $dir = shift;

	my @entries;
	eval {
		opendir(my $dh, $dir);
		@entries = grep { !/\A\./ } readdir($dh);
		closedir($dh);
	};

	return \@entries;
}

# _workspace_sources
# Purpose      : Every source file that might consume a result: those of the
#                sibling distributions and, with own_consumers, this one's.
# Entry        : A constructed object.
# Exit status  : An arrayref of paths, spelled as the contract spells them.
# Side effects : Walks the file system.
# Notes        : Sibling paths are workspace-relative.  The checked
#                distribution's are dist-relative, like its producers, so they
#                still point at the right file when it is installed under a
#                versioned directory name.  Its t/ is not scanned: its tests
#                prove the value object rather than consume it.
sub _workspace_sources :Private
{
	my $self = shift;

	my @files;
	foreach my $dist (sort @{_children($self->{'workspace'})}) {
		next if($dist eq $self->{'dist_name'});

		my $dir = File::Spec->catdir($self->{'workspace'}, $dist);
		next unless(-d $dir);

		push @files, @{$self->_sources_below($dir, $self->{'workspace'}, $self->{'config'}{'sibling_dirs'})};
	}

	push @files, @{$self->_sources_below($self->{'dist_root'}, $self->{'dist_root'}, $self->{'config'}{'own_dirs'})}
		if($self->{'own_consumers'});

	return \@files;
}

# _sources_below
# Purpose      : The source files of one distribution.
# Entry        : $dir -- the distribution; $base -- what the names are
#                relative to; $subdirs -- the directories to walk.
# Exit status  : An arrayref of relative paths, '/'-separated.
# Side effects : Walks the file system.
sub _sources_below :Private
{
	my ($self, $dir, $base, $subdirs) = @_;

	my $extension = $self->_extension_re();
	my @files;

	foreach my $root (grep { -d $_ } map { File::Spec->catdir($dir, $_) } @{$subdirs}) {
		File::Find::find({
			no_chdir => 1,
			wanted   => sub {
				my $path = $File::Find::name;
				$File::Find::prune = 1 if(-d $path && $self->_skipped_dir($path));
				return unless(-f $path && ($path =~ $extension || $self->_program($path)));
				push @files, $self->_ported(File::Spec->abs2rel($path, $base));
			},
		}, $root);
	}

	# Programs at the distribution root: a program needs neither an extension
	# nor a bin/ to be one - ged2map is at the root of HTML-Genealogy-Map - and
	# its loop is often a copy of a module's.
	push @files, map { $self->_ported(File::Spec->abs2rel($_, $base)) }
		grep { -f $_ && $self->_program($_) }
		map { File::Spec->catfile($dir, $_) } @{_children($dir)};

	return \@files;
}

# _extension_re
# Purpose      : The file names that hold Perl source, from the configuration.
# Entry/Exit   : A constructed object / a qr// anchored at the end.
# Side effects : Caches the regex in the object.
sub _extension_re :Private
{
	my $self = shift;

	return $self->{'_cache'}{'extension_re'} //=
		qr/\.(?:@{[ join('|', map { quotemeta } @{$self->{'config'}{'source_extensions'}}) ]})\z/;
}

# _program
# Purpose      : Whether an extensionless file is a program.
# Entry        : $path -- a file.
# Exit status  : 1 when its name has no '.' and it starts with '#!', else 0.
# Side effects : Reads two bytes of the file.
# Notes        : The executable bit is advisory, and on Windows true for most
#                files, so the file is asked what it is.  README, Changes and
#                LICENSE have no extension either, and none starts with '#!'.
sub _program :Private
{
	my (undef, $path) = @_;

	# Two bytes, not a line: a line of a binary file can be all of it.
	my $magic = '';
	if(basename($path) !~ /\./) {
		eval { open(my $fh, '<:raw', $path); read($fh, $magic, length($SHEBANG)); close($fh) };
	}

	return ($magic eq $SHEBANG) ? 1 : 0;
}

# _ported
# Purpose      : A path spelled the way the contract spells paths, with '/'
#                between directories whatever the platform uses.
# Entry/Exit   : $path / the path with every '\' turned into '/'.
# Side effects : None.  File::Spec->abs2rel() answers with '\' on Windows,
#                which matched no registry key and made every consumer
#                unregistered there.
sub _ported :Private
{
	my (undef, $path) = @_;

	(my $ported = $path) =~ s{\\}{$SEPARATOR}g;

	return $ported;
}

# _skipped_dir
# Purpose      : Whether a directory holds something other than this
#                checkout's source: a build product, a bundled dependency,
#                another version control tree.
# Entry/Exit   : $path / 1 or 0.
# Side effects : Caches the regex in the object.
# Notes        : The name is matched after a separator of either spelling,
#                because File::Find names files the platform's way: matched
#                after '/' only, this pruned nothing on Windows.
sub _skipped_dir :Private
{
	my ($self, $path) = @_;

	my $skipped = $self->{'_cache'}{'skipped_re'} //=
		qr{[/\\](?:@{[ join('|', map { quotemeta } @{$self->{'config'}{'skipped_dirs'}}) ]})\z};

	return ($path =~ $skipped) ? 1 : 0;
}

# _ignored
# Purpose      : The reason a file is ignored, if an 'ignored' rule covers it.
# Entry/Exit   : $rel -- a contract-spelled path / the reason (1 when the
#                rule gives none), or undef.
# Side effects : None.
sub _ignored :Private
{
	my ($self, $rel) = @_;

	my $rule = first { index($rel, $_->[0]) == 0 } @{$self->{'ignored'}};

	return $rule ? ($rule->[1] // 1) : undef;
}

=head2 documented_accessors

    my @names = $contract->documented_accessors($source);
    my $names = $contract->documented_accessors($source);

=head3 Purpose

Every name the value object's source documents as part of its interface: its
C<=head2> headings and the public subs it defines.  C<=head1> headings are left
out (NAME, VERSION and the rest of the boilerplate), as are deeper headings,
which are sections about the accessor above them rather than accessors, and
private subs.  A method implemented through C<AUTOLOAD> is found by its
heading, which is what makes this the list of what is documented rather than
of what is compiled.

=head3 Arguments

=over 4

=item C<$text> (string, required) - the value object's source, POD included.

=back

=head3 Returns

The names, sorted and unique: a list in list context, an arrayref in scalar
context.

=head3 Side Effects

None.

=head3 EXAMPLE

    my $names = $contract->documented_accessors("=head2 x\n\n=head3 PURPOSE\n\n=cut\n\nsub y {}\n");
    # ['x', 'y']

=head3 API SPECIFICATION

=head4 Input

    { text => { type => 'string', position => 0 } }

=head4 Output

    { type => 'arrayref', element => { type => 'string' } }

=head3 MESSAGES

    Message                                          Meaning / Resolution
    -----------------------------------------------  ----------------------------------
    "...::documented_accessors() needs a 'text'"     The text is missing or undef.

=head3 FORMAL SPECIFICATION

    ┌─ DocumentedAccessors ─────────────────────────────────────
    │ text? : seq CHAR
    │ names! : seq NAME
    ├───────────────────────────────────────────────────────────
    │ ran names! = head2(text?) ∪ { s : subs(text?) | s(1) ≠ '_' }
    │ names! is sorted ∧ names! ∈ iseq NAME
    └───────────────────────────────────────────────────────────

=cut

sub documented_accessors
{
	my $self = shift;
	my $text = $self->_arguments('documented_accessors', ['text'], { text => { type => 'string' } }, @_)->{'text'};

	my %found;

	# =head2 only.  A deeper heading is a section about the one above it: a
	# value object documenting each accessor with '=head2 score' and then
	# '=head3 PURPOSE' has one accessor there, not two.
	$found{$1} = 1 while($text =~ /^=head2\s+(?:B<)?(\w+)/gm);
	$found{$1} = 1 while($text =~ /^sub\s+([A-Za-z]\w*)/gm);

	my @names = sort keys %found;

	return wantarray ? @names : set_return(\@names, { type => 'arrayref' });
}

# _check_accessors
# Purpose      : Check 4: the accessor lists match the value object, both ways.
# Entry        : A constructed object.
# Exit status  : Returns $self.
# Side effects : One subtest when value_object and an accessor list are
#                declared; loads the class and reads its file.
sub _check_accessors :Protected
{
	my $self = shift;

	my @accessors = @{$self->{'accessors'}};
	my @not_accessors = sort keys %{$self->{'not_accessors'}};

	return $self unless($self->{'value_object'} && (@accessors || @not_accessors));

	my $class = $self->{'value_object'}{'class'};

	subtest $self->i18n('check.accessors') => sub {
		$self->_class_ready($class) or return;

		my $text = $self->_readable($INC{module_notional_filename($class)} // '', $class);
		return unless(defined($text));

		# One idea of "documented" for both directions; the first used to accept
		# a 'sub name' anywhere in the file, the second only at column 0.
		my %documented = map { $_ => 1 } @{scalar($self->documented_accessors($text))};

		# What the declaration names is what the value object has: an accessor
		# that has gone, or has been renamed, fails rather than being described.
		foreach my $accessor (@accessors, @not_accessors) {
			ok($class->can($accessor) || $documented{$accessor},
				$self->i18n('accessor.documented', { accessor => $accessor, class => $class }));
		}

		# And what the value object documents is what the declaration names:
		# without this a value object that gains an accessor leaves the
		# declaration behind, and the next reader of it is never checked.
		my %accounted = map { $_ => 1 } (@accessors, @not_accessors, keys %{$self->{'conditional'}});
		my @unlisted = grep { !$accounted{$_} } sort keys %documented;

		$self->_expect_none(\@unlisted, $self->i18n('accessor.accounted', { class => $class }), [
			split(/\n/, $self->i18n('accessor.drift',
				{ class => $class, names => _list(map { "'$_'" } @unlisted), count => scalar(@unlisted) })),
		]);
	};

	return $self;
}

# _check_discovery
# Purpose      : Check 5: every file that reads a result is registered.
# Entry        : A constructed object.
# Exit status  : Returns $self.
# Side effects : One subtest; walks and reads the workspace.
sub _check_discovery :Protected
{
	my $self = shift;

	my $source = $self->{'source'};
	my $consumers = $self->{'consumers'};

	subtest $self->i18n('check.discovery') => sub {
		$self->_skip_without_siblings();

		my (@unregistered, @discovered);
		my $checked = 0;
		foreach my $rel (@{$self->_workspace_sources()}) {
			my $raw = $self->_read_source($self->consumer_path($rel))->{'text'};
			next unless(defined($raw) && index($raw, $source) >= 0);

			$checked++;
			next unless(@{$self->reads_of_results($self->strip($raw))});

			push @discovered, $rel;
			push @unregistered, $rel unless(exists($consumers->{$rel}) || defined($self->_ignored($rel)));
		}

		cmp_ok($checked, '>', 0, $self->i18n('discovery.checked', { source => $source, count => $checked }));

		# Without this the whole subtest could pass by finding nothing at all.
		ok(scalar(grep { exists($consumers->{$_}) } @discovered),
			$self->i18n('discovery.registered', { count => scalar(@discovered) }));

		$self->_expect_none(\@unregistered, $self->i18n('discovery.clean', { source => $source }), [
			$self->i18n('discovery.header', { source => $source }),
			@unregistered,
			split(/\n/, $self->i18n('discovery.advice', { count => scalar(@unregistered) })),
		]);
	};

	return $self;
}

1;

__END__

=head1 DIAGNOSTICS

Every message is a key in the catalogue (see L</i18n>); the English text is
summarised below.  Diagnostics after a failed assertion are indented a tab.

    Key                  Meaning / Resolution
    -------------------  ---------------------------------------------------------
    file.unreadable      A producer, consumer or value object could not be read;
                         the OS error says why.  Fix the path in the declaration.
    producer.sets        (test name) A producer no longer sets the key.  Set it
                         again, or take it out of the producer's list.
    class.unavailable    (skip) The value object is not in @INC.  Add its lib to
                         'include', or accept the skip on a CPAN install.
    class.compiles       (test name) The value object is in @INC but does not
                         load; the error follows.  Fix the class.
    derivation.made      (test name) The constructor died or returned false; the
                         error follows.
    consumer.offender    A consumer reads a key not every producer sets.  Stop
                         reading it, or register it in may_rely_on with why.
    consumer.stale       A may_rely_on entry is no longer read.  Remove it.
    skip.siblings        (skip) A require_workspace distribution is absent.
    accessor.documented  (test name) A name in accessors/not_accessors is not
                         documented or defined by the value object.
    accessor.drift       The value object documents a name the contract does not
                         mention.  Put it in accessors, conditional or
                         not_accessors.
    discovery.header     A file reads a result and is neither registered nor
                         ignored.  Register it, or ignore it with a reason.

=head1 LIMITATIONS

=over 4

=item * The scanner is lexical, not syntactic.  It reads Perl with regular
expressions, so a read inside a string or a heredoc can be taken for code, a
trailing comment is not removed (only whole-line comments are), and an unusual
layout can hide a read.  L<PPI> is the tool that would parse the code properly;
moving the scanner onto it is the change that would retire most of the items
below, at the cost of speed and a heavier dependency.

=item * Variables are matched by name across the whole file.  A C<$point>
bound from a producing call in one sub makes every C<$point> in every other sub
a result too, and a C<map> or C<grep> over a list method makes C<$_> a result
file-wide.

=item * A sub is found only when C<sub NAME> starts in column 0, and it ends at
the next C<}> in column 0 (or on its own line, when its braces close there).
Subs inside an indented C<package NAME { ... }> block, or closed by an indented
brace, are reported as file scope.  Signatures (C<sub f ($self, $r)>) are not
read, so a helper declared with one is not followed.

=item * A single result stored in a hash or returned is not followed; only a
value out of a batch is.  Helpers are followed by variable name until nothing
new is found.

=item * Discovery requires the file to contain the C<source> string.  A
consumer that is handed results without naming it is not picked up; add it to
C<consumers> by hand.

=item * Extensionless files are discovered by their shebang.  A program
without one - a compiled binary, a file run through an explicit interpreter -
is not seen.  C<xt/> is never scanned, in any distribution.

=item * The producer evidence is static: a producer that sets a key by a route
the recognised spellings do not cover (C<$hash{key} = ...>, a key computed at
run time) is reported as not setting it.

=item * C<require_workspace> is what tells a missing checkout apart from a
passing one.  With nothing to require, a distribution checked on its own has
no sibling consumers to find and the discovery check fails on finding none.

=item * The accessor check reads the value object's own file, so an accessor
it inherits, or documents in another file, is not seen unless C<can()> finds
it.  A heading or sub that names something which is not an accessor of a
result has to be listed in C<not_accessors>.

=item * C<consumer_path()> looks in the workspace first, so a dist-relative
consumer whose path also exists under the workspace is read from the
workspace.

=item * C<include> changes C<@INC> for the whole process, not for the object.

=item * The private subs are wrapped by L<Sub::Private> in C<enforce> mode,
and the C<_check_*> subs by L<Sub::Protected>.  Enforce mode is a process-wide
setting of Sub::Private, so loading this module switches any other module that
uses C<:Private> into enforce mode too.  Calls from outside the package croak
unless C<$Sub::Private::BYPASS> or C<HARNESS_ACTIVE> is set.

=item * Each line number is counted from the start of the file, so a file with
very many reads is scanned in quadratic time.

=item * The end-to-end tests match the English wording of the messages; a
translation passed through C<messages> is for users, not for this module's own
test suite.

=back

=head1 AUTHOR

Nigel Horne, C<< <njh at nigelhorne.com> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2026 Nigel Horne.

Usage is subject to the GPL2 licence terms.

=cut
