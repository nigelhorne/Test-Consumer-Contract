#!/usr/bin/env perl

# Unit tests for the parts of the contract checker that read source: which
# variables hold a result, what a read of one looks like, how a producer's
# assignment is recognised, and which directories it walks past.  The three
# checks themselves are exercised end to end in t/contract.t.

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::Most;
use Test::Consumer::Contract;

my $contract = Test::Consumer::Contract->new(
	source     => 'Widget::Maker',
	producers  => {},
	guaranteed => [],
);

subtest 'a key read through a bound result is a read' => sub {
	my @reads = $contract->reads_of_results(<<'SOURCE');
my $widget = $maker->geocode(location => 'London');
return $widget->{'colour'};
SOURCE

	is(scalar(@reads), 1, 'one read') or diag(explain(\@reads));
	is($reads[0][0], 'colour', 'the key is named');
	is($reads[0][1], 2, 'the line number is the real one');
	is($reads[0][2], 'key', 'it is a hash key, not an accessor');
	is($reads[0][3], '(file scope)', 'no sub encloses it');
};

subtest 'a result passed to a helper is followed into it' => sub {
	my @reads = $contract->reads_of_results(<<'SOURCE');
my $point = $geocoder->reverse_geocode(lat => 1, long => 2);
_place($point);

sub _place
{
	my $point = shift;

	return $point->{'county'};
}
SOURCE

	is(scalar(@reads), 1, 'one read, found inside the helper') or diag(explain(\@reads));
	is($reads[0][0], 'county', 'the key is named');
	is($reads[0][3], '_place', 'the enclosing sub is named');
};

subtest 'an accessor call is a read, and so is an inspection' => sub {
	my @reads = $contract->reads_of_results(<<'SOURCE');
my $point = $geocoder->geocode(location => 'London');
return $point->latitude() if($point->can('latitude'));
SOURCE

	my %by_key = map { $_->[0] => $_->[2] } @reads;
	is_deeply(\%by_key, { latitude => 'accessor', can => 'accessor' },
		'both are accessor calls') or diag(explain(\@reads));
};

subtest 'POD and comments are not reads of a result' => sub {
	my $text = $contract->strip(<<'SOURCE');
# $widget->{'comment'} is in a comment
=head1 NAME

Widget::User - the $widget->{'pod'} key in prose is not a read

=cut

my $widget = $maker->geocode(location => 'London');
return $widget->{'x'};
SOURCE

	my @reads = $contract->reads_of_results($text);
	is(scalar(@reads), 1, 'only the real read is found') or diag(explain(\@reads));
	is($reads[0][0], 'x', 'and it is the real key');
	is($reads[0][1], 9, 'the line number survives stripping');
};

subtest 'the spellings that count as a producer setting a key' => sub {
	ok($contract->sets_key("colour => 'red'", 'colour'), 'bare key');
	ok($contract->sets_key("'colour' => 'red'", 'colour'), 'quoted key');
	ok($contract->sets_key('$widget->{\'colour\'} = \'red\'', 'colour'), 'assignment through the object');
	ok($contract->sets_key('$widget->{\'colour\'} //= \'red\'', 'colour'), 'defaulted assignment');

	ok(!$contract->sets_key("my \$colour = 'red'", 'colour'), 'a lexical is not the key');
	ok(!$contract->sets_key("colourblind => 1", 'colour'), 'a longer key is not the key');
	ok(!$contract->sets_key('$widget->colour()', 'colour'), 'calling an accessor is not setting the key');
};

subtest 'a path is judged the same whatever separator it is written with' => sub {
	ok($contract->_skipped_dir('/ws/Widget-User/blib'), 'a POSIX path to a build product is walked past');
	ok($contract->_skipped_dir('C:\\ws\\Widget-User\\blib'), 'and the Windows path to one, which used to be walked into');
	ok($contract->_skipped_dir('C:\\ws\\Widget-User\\.git'), 'a nested version control tree is walked past');
	ok(!$contract->_skipped_dir('C:\\ws\\Widget-User\\lib'), 'an ordinary directory is not');

	is($contract->_ported('Widget-User\\lib\\Widget\\User.pm'), 'Widget-User/lib/Widget/User.pm',
		'a platform path is spelled the way the contract spells files');
	is($contract->_ported('Widget-User/lib/Widget/User.pm'), 'Widget-User/lib/Widget/User.pm',
		'and one already spelled that way is left alone');
};

subtest 'a result taken out of a batch is followed, and the batch itself is not' => sub {
	my @reads = $contract->reads_of_results(<<'SOURCE');
my $batch = $geocoder->geocode_many(['London']);
my $count = $batch->{'lookups'};
my $point = (ref($batch) eq 'HASH') ? $batch->{'London'} : undef;
_coordinates($point);

sub _coordinates
{
	my $point = shift;

	return $point->{'lat'};
}
SOURCE

	my @keys = map { $_->[0] } @reads;
	is_deeply(\@keys, ['lat'], 'only the read off the result is found')
		or diag(explain(\@reads));
	is($reads[0][3], '_coordinates', 'and it was followed into the helper it was passed to');
};

subtest 'a program is recognised by its shebang, not by a bin directory' => sub {
	my $dir = tempdir(CLEANUP => 1);

	my $program = File::Spec->catfile($dir, 'map-events');
	open(my $out, '>', $program) or die "Cannot write $program: $!";
	print {$out} "#!/usr/bin/env perl\n\nprint \"hi\\n\";\n";
	close($out) or die "Cannot close $program: $!";

	my $document = File::Spec->catfile($dir, 'Changes');
	open(my $doc, '>', $document) or die "Cannot write $document: $!";
	print {$doc} "Revision history\n\n0.01  the first version\n";
	close($doc) or die "Cannot close $document: $!";

	ok($contract->_program($program), 'an extensionless file that starts with #! is a program');
	ok(!$contract->_program($document), 'an extensionless document is not');
	ok(!$contract->_program(__FILE__), 'and a file with an extension is not one of these');
};

subtest 'workspace_present answers before a check has needed the cache' => sub {
	my $dir = tempdir(CLEANUP => 1);
	make_path(File::Spec->catdir($dir, 'Widget-User'));

	my $present = Test::Consumer::Contract->new(
		source            => 'Widget::Maker',
		guaranteed        => [],
		workspace         => $dir,
		require_workspace => ['Widget-User'],
	);
	ok($present->workspace_present(), 'a checkout that is there');

	my $missing = Test::Consumer::Contract->new(
		source            => 'Widget::Maker',
		guaranteed        => [],
		workspace         => $dir,
		require_workspace => ['No-Such-Distribution'],
	);
	ok(!$missing->workspace_present(), 'and one that is not');
};

subtest 'a bare statement is not mistaken for a bound result' => sub {
	my @reads = $contract->reads_of_results(<<'SOURCE');
$maker->geocode(location => 'London');
my $colour = 'red';
print $colour->{'not_a_read'};
SOURCE

	is(scalar(@reads), 0, 'nothing is read off a result') or diag(explain(\@reads));
};

done_testing();
