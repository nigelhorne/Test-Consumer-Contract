## Name

Test::Consumer::Contract - check a reader against the keys its producer promises

## Synopsis

A distribution declares what its value object promises, who produces it, who
reads it, and why each exception is safe:

```perl
use Test::Consumer::Contract qw(run_consumer_contract);

run_consumer_contract(
    source        => 'Widget::Maker',
    # Required: the producing calls, as this producer spells them.  Nothing
    # in the checker knows what a geocoder looks like.
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
```

Then it runs these checks:

- 1. the producers still set the keys the contract claims

    Each file named in `producers` (and `workspace_producers`) is read and each key
    it is responsible for must still be assigned there, so a producer that quietly
    stops stamping a key fails.

- 2. registered consumers read only what every producer sets

    Each file named in `consumers` is scanned for reads of a result.  A read of a
    key in `guaranteed` is fine; a read of anything else is reported with its file,
    line, sub and the reason the key is a problem, unless the read is registered
    under `may_rely_on` keyed by the name of the enclosing sub.  An entry that is no
    longer read is reported as stale, so the registry keeps describing the code.

- 3. every discovered consumer is registered

    Files in sibling distributions that receive a result but are named in neither
    `consumers` nor `ignored` fail the check, so a new consumer cannot slip past
    check 2 unnoticed.  A consumer is not necessarily a module: a program without an
    extension is discovered too, when it starts with a shebang, because a script can
    hold the same reader as the module beside it.

- 4. the accessor lists match the value object, in both directions

    The value object's documented accessors are the `=head2` (and deeper) headings
    of its source and the public subs it defines.  Each one the declaration names in
    `accessors` or `not_accessors` must be an accessor the value object really has,
    and - the direction that matters when a value object grows - each one the value
    object documents must be accounted for in `accessors`, `not_accessors` or
    `conditional`.  `conditional` is where a documented accessor belongs when only
    some results carry it.  So a value object that gains a documented accessor
    cannot leave the declaration behind: the check fails, naming the accessor and the
    three places to put it.

Checks 2 and 3 need the sibling distributions that share a workspace; on a
CPAN-style install they skip with a diagnostic and only check 1 runs.  Check 4
needs the value object's own file, which `include` puts in reach.  This is a
static, lexical check: it reads source, it does not run the producer.

## The rules, and the tests that prove them

Everything check 2 does beyond reading a file is a rule of the scanner, and each
rule is named in the inventory the module owns: one name per rule, with the sub
the rule is exercised through.

```perl
my %seam = Test::Consumer::Contract->scanner_capabilities();
```

`t/contract.t` runs a mutation subtest for every name in that list - the rule put
back the way it was before it was written, in the subprocess the scenario runs
in, with the failure it used to let through shown to come back - and then fails
if any rule in the inventory has no such subtest, or if a mutation names a rule
the inventory does not have, or if the sub a row names is not one the module
defines.  A rule that nobody has shown catches anything is a rule that may be
doing nothing, so adding a behaviour to the scanner means adding its failure and
its mutation in the same change.  The subtests all go through one helper, so a
mutation cannot be written in a way the guard does not see.

## Requirements

The caller must load a test module ([Test::Most](https://metacpan.org/pod/Test%3A%3AMost) is what this module uses) and
call `done_testing()` after `run_consumer_contract()`; this module adds
subtests but does not end the plan.

### **New**

Takes the declaration above as a list.  `source`, `guaranteed` and `methods` are
required; every other option has a default:

- `dist_root`

    The distribution being checked.  Defaults to the parent of the directory
    holding the running test file, falling back to the current directory when that
    is not a distribution root.

- `workspace`

    The directory holding the sibling distributions.  Defaults to the parent of
    `dist_root`.

    Every path in a declaration - in `include`, `producers`,
    `workspace_producers`, `consumers` and `ignored` - is written with `/`
    between the directories, whatever separator the platform itself uses, and the
    paths in `consumers` and `ignored` are relative to the workspace.  The checks
    name files the same way, so a path can be copied from a failure message into the
    declaration unchanged.

- `include`

    Workspace-relative lib directories to put at the front of `@INC`, so a value
    object is read from the checkout in the workspace rather than from an installed
    copy.

- `conditional`

    Key => why it is not guaranteed, used in the failure messages.

- `workspace_producers`

    Like `producers`, but paths are relative to the workspace: producers in a
    sibling distribution that this distribution's value object comes from.

- `not_accessors`

    Documented accessors of the value object that are not a slot of one result - the
    constructor, a class constant - as name => why, so that the accessor check can be
    satisfied by saying what a name is instead of listing it as something a consumer
    may read.  A name here that the value object does not document fails, as an entry
    in `accessors` would.

- `methods`

    Required.  The calls that hand a result to the caller, as your producer spells
    them - `[qw(geocode reverse_geocode)]` for a geocoder, `[qw(fetch scan)]` for a
    store.  There is no default: the checker cannot guess what your producer calls
    its lookups, and a name it guessed would quietly find nothing.  A variable
    bound from one of these is followed, as is a variable passed to a sub as its
    first parameter.

    A method named in `batch_methods` instead returns a batch rather than one
    result: its keys are the results,
    plus counts about the batch itself.  A variable bound from a batch method is
    therefore not treated as a result - `$batch->{'lookups'}` is not a read of
    one - while a value taken out of it is, wherever it is put: `my $point =
    $batch->{$value}` makes `$point` a result, `my %points = map { $_ =>
    $batch->{$_} } @values` makes a read through `$points{$value}` a read of a
    result, and a sub that does `return $batch->{$value}` hands one back to its
    callers, who are then read like any other consumer's.

- `batch_methods`

    The producing methods that return a batch of results rather than one result;
    none by default.  A variable bound from one is a batch, not a result.

- `list_methods`

    The producing methods that hand back a list of results rather than one - a
    report's `results()`, the checks a runner ran; none by default.  The reader
    takes a result out of the list, and the variable that takes it is a result
    like any other: the loop variable of `for my $entry (@{ $report->results() })`,
    of a list assigned from that call first, and the topic of a `map` or `grep`
    block over it.

- `own_consumers`

    True when the distribution being checked is one of its own value object's
    readers, which is how a value object that is a class in the distribution
    making it is read; false by default.  Its `lib`, `bin` and `scripts` are then
    scanned for consumers and discovered like a sibling's, but not its `t` and
    `xt`: its tests are the proof of the value object rather than readers of it,
    and every one of them reads it.  Its paths are named relative to the
    distribution, the way a producer's are, so they still point at the right file
    when the distribution is installed under a versioned directory name.

- `require_workspace`

    Sibling distribution names that must exist for checks 2 and 3 to run.  Pass the
    ones your consumers live in, or those checks cannot tell a missing checkout from
    a passing one.

Unknown options are an error rather than being silently ignored.

### **Run**

Runs the three checks as subtests.  Called for you by
`run_consumer_contract()`.

### **Run\_Consumer\_Contract**

```perl
my $contract = run_consumer_contract(%declaration);
```

Builds the contract and runs it, returning the object.

### **Workspace\_Present**

True when every distribution named in `require_workspace` is in the workspace.

### **Sets\_Key**

```
$contract->sets_key($source_text, 'database')
```

True when the text assigns the key, in any of the spellings a producer might
use: `key => value`, `'key' => value`, `$obj->{'key'} = value`.

### **Strip**

Returns the source with POD and comments replaced by blank space, preserving
line numbers.

### **Reads\_of\_Results**

```perl
my @reads = $contract->reads_of_results($stripped_text);
```

Every `->{key}` and `->method()` read of a variable that holds a
result, as `[key, line, kind, sub]`, in the order the reads appear in the file.
A variable holds one if it is bound from a call the declaration names in
`methods`, if it is the parameter a sub takes it in when this file calls that
sub with such a variable - so a helper that takes the result still counts,
whatever it names it, whether the helper is written `helper($result)` or
`$self->_helper($result)` - or if it is bound from a sub that returns a value
taken out of a batch.  A value out of a batch is a result wherever it is put:
into a variable of its own, into a hash (a read through `$points{$value}` is
then a read of a result), or back out of a sub through a `return`.  One level of
that is followed, which is enough for an adapter; a deeper chain is a sign the
read belongs in the consumer's registry entry.

An accessor is read with its parentheses or without them - `$result->score()`
and `$result->score` are the same read - and `can()`, `isa()` and the rest of
`inspection` are reads too, reported as such rather than as fields.

### **Documented\_Accessors**

```perl
my @names = $contract->documented_accessors($source);
```

Every name the value object's source documents as part of its interface: its
`=head2` (and deeper) headings and the public subs it defines.  `=head1`
headings are left out - they are NAME, VERSION, SEE ALSO and the rest of the
boilerplate, which document no accessor - and so are the private subs, whose
leading underscore keeps them out of the interface.  A method the value object
documents but implements through `AUTOLOAD` is found by its heading, which is
what makes this the list of what is documented rather than of what is compiled.

## Limitations

- The scanner is static and lexical.  It follows reads on variables bound
from a producing call plus one level of call into a helper; a single result
stored in a hash or returned is not followed, and neither is anything passed
through two helpers.  A value taken out of a `geocode_many()` batch is the
exception: it is a result wherever a hash or a `return` puts it.
- Discovery requires the file to name the source distribution.  A consumer
that is handed results without naming the distribution is not picked up; add it
to `consumers` by hand.
- Extensionless files are discovered by their shebang.  A program without
one - a compiled binary, a file run through an explicit interpreter - is not
seen; register it by hand.
- Files in the `dist_root` distribution are not scanned for consumption by
default - its own sources are treated as the producer.  A consumer that lives in
the producing distribution is not discovered until the declaration asks for it
with `own_consumers`, and then its `t` and `xt` are still left out.
- The producer evidence is static: a producer that sets a key by a route
the three recognised spellings do not cover is reported as not setting it.
- `require_workspace` is what tells a missing checkout apart from a
passing one.  With nothing to require, a distribution checked on its own has no
sibling consumers to find and the discovery check will fail on finding none.
- The accessor check reads the value object's own file, so an accessor it
inherits, or documents in another file, is not seen.  A heading or sub that names
something which is not an accessor of a result - a constructor, a constant - has
to be listed in `not_accessors`, which is what that option is for; the check
then holds the entry to the value object, so a renamed or removed name fails
rather than sitting in the list unread.

## Author

Nigel Horne, `<njh at nigelhorne.com>`

## License and Copyright

Copyright 2026 Nigel Horne.

Usage is subject to the GPL2 licence terms.
