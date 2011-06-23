#!/usr/bin/env perl
use 5.010;
use strict;
use warnings;
use utf8;

=head1 NAME

10-testrunner.t - basic test for testrunner.pl

=head1 SYNOPSIS

  perl ./10-testrunner.t

This test will run the testrunner.pl script with a few different
types of subprocesses and verify that behavior is as expected.

=cut

use Encode;
use FindBin;
use Readonly;
use Test::More;
use Capture::Tiny qw( capture );

use lib "$FindBin::Bin/../../lib/perl5";
use QtQA::Test::More qw( is_or_like );

# perl to print @ARGV unambiguously from a subprocess
# (not used directly)
Readonly my $TESTSCRIPT_BASE
    => q{use Data::Dumper; print Data::Dumper->new( \@ARGV )->Indent( 0 )->Dump( ); };

# perl to print @ARGV unambiguously and exit successfully
Readonly my $TESTSCRIPT_SUCCESS
    => $TESTSCRIPT_BASE . 'exit 0';

# perl to print @ARGV unambiguously and exit normally but unsuccessfully
Readonly my $TESTSCRIPT_FAIL
    => $TESTSCRIPT_BASE . 'exit 3';

# perl to print @ARGV unambiguously and crash
Readonly my $TESTSCRIPT_CRASH
    => $TESTSCRIPT_BASE . 'kill 11, $$';

# expected STDERR when wrapping the above;
# note that we have no way to control if the system will create core dumps or not,
# so we will accept either case
Readonly my $TESTERROR_CRASH
    => qr{\AQtQA::App::TestRunner: Process exited due to signal 11(?:; dumped core)?\n\z};

# perl to print @ARGV unambiguously and hang
Readonly my $TESTSCRIPT_HANG
    => $TESTSCRIPT_BASE . 'while (1) { sleep(1000) }';

# hardcoded value (seconds) for timeout test
Readonly my $TIMEOUT
    =>  2;

# expected STDERR when wrapping the above
Readonly my $TESTERROR_HANG => qr{

        \A
        QtQA::App::TestRunner:\ Timed\ out\ after\ \d+\ seconds?\n
        QtQA::App::TestRunner:\ Process\ exited\ due\ to\ signal\ 15\n
        \z

}xms;


# Various interesting sets of arguments, with their expected serialization from
# the subprocess.
#
# This dataset essentially aims to confirm that there is never any special munging
# of arguments, and arguments are always passed to the subprocess exactly as they
# were passed to the testrunner.
#
# Note that the right hand side of these assignments of course could be generated
# by using Data::Dumper in this test rather than writing it by hand, but this
# is deliberately avoided to reduce the risk of accidentally writing an identical
# bug into both this test script and the test subprocess.
Readonly my %TESTSCRIPT_ARGUMENTS => (

    'no args' => [
        [
        ] => q{},
    ],

    'trivial' => [
        [
            'hello',
        ] => q{$VAR1 = 'hello';},
    ],

    'whitespace' => [
        [
            'hello there',
            ' ',
        ] => q{$VAR1 = 'hello there';$VAR2 = ' ';},
    ],

    'posix sh metacharacters' => [
        [
            q{hello |there},
            q{how $are "you' !today},
        ] => q{$VAR1 = 'hello |there';$VAR2 = 'how $are "you\' !today';},
    ],

    'windows cmd metacharacters' => [
        [
            q{hello %there%},
            q{how ^are "you' today},
        ] => q{$VAR1 = 'hello %there%';$VAR2 = 'how ^are "you\' today';},
    ],

    'non-ascii' => [
        [
            q{早上好},
            q{你好马？},
        ] => encode_utf8( q{$VAR1 = '早上好';$VAR2 = '你好马？';} ),
    ],
);

# Do a single test of QtQA::App::TestRunner->run( )
sub test_run
{
    my ($params_ref) = @_;

    my @args              = @{$params_ref->{ args }};
    my $expected_stdout   =   $params_ref->{ expected_stdout };
    my $expected_stderr   =   $params_ref->{ expected_stderr };
    my $expected_success  =   $params_ref->{ expected_success };
    my $testname          =   $params_ref->{ testname }          || q{};

    my $status;
    my ($output, $error) = capture {
        $status = system( 'perl', "$FindBin::Bin/../testrunner.pl", @args );
    };

    if ($expected_success) {
        is  ( $status, 0, "$testname exits zero" );
    }
    else {
        isnt( $status, 0, "$testname exits non-zero" );
    }

    is_or_like( $output, $expected_stdout, "$testname output looks correct" );
    is_or_like( $error,  $expected_stderr, "$testname error looks correct" );

    return;
}

sub test_success
{
    while (my ($testdata_name, $testdata_ref) = each %TESTSCRIPT_ARGUMENTS) {
        test_run({
            args                =>  [ 'perl', '-e', $TESTSCRIPT_SUCCESS, @{$testdata_ref->[0]} ],
            expected_stdout     =>  $testdata_ref->[1],
            expected_stderr     =>  q{},
            expected_success    =>  1,
            testname            =>  "successful $testdata_name",
        });
    }

    return;
}

sub test_normal_nonzero_exitcode
{
    while (my ($testdata_name, $testdata_ref) = each %TESTSCRIPT_ARGUMENTS) {
        test_run({
            args                =>  [ 'perl', '-e', $TESTSCRIPT_FAIL, @{$testdata_ref->[0]} ],
            expected_stdout     =>  $testdata_ref->[1],
            expected_stderr     =>  q{},
            expected_success    =>  0,
            testname            =>  "failure $testdata_name",
        });
    }

    return;
}

sub test_crashing
{
    while (my ($testdata_name, $testdata_ref) = each %TESTSCRIPT_ARGUMENTS) {
        test_run({
            args                =>  [ 'perl', '-e', $TESTSCRIPT_CRASH, @{$testdata_ref->[0]} ],
            expected_stdout     =>  undef,  # output is undefined when crashing
            expected_stderr     =>  $TESTERROR_CRASH,
            expected_success    =>  0,
            testname            =>  "crash $testdata_name",
        });
    }

    return;
}

sub test_hanging
{
    while (my ($testdata_name, $testdata_ref) = each %TESTSCRIPT_ARGUMENTS) {
        my @args = (
            # timeout after some seconds
            '--timeout',
            $TIMEOUT,

            'perl',
            '-e',
            $TESTSCRIPT_HANG,
            @{$testdata_ref->[0]},
        );
        test_run({
            args                =>  \@args,
            expected_stdout     =>  undef,  # output is undefined when killed from timeout
            expected_stderr     =>  $TESTERROR_HANG,
            expected_success    =>  0,
            testname            =>  "hanging $testdata_name",
        });
    }

    return;
}

# Test that testrunner.pl parses its own arguments OK and does not steal arguments
# from the child process
sub test_arg_parsing
{
    # basic test: testrunner.pl with no args will fail
    test_run({
        args                =>  [],
        expected_stdout     =>  q{},
        expected_stderr     =>  qr{not enough arguments},
        expected_success    =>  0,
        testname            =>  "fails with no args",
    });

    # basic test: testrunner.pl parses --help by itself, and stops
    test_run({
        args                =>  [ '--help', 'perl', '-e', 'print "Hello\n"' ],
        expected_stdout     =>  qr{\A Usage: \s}xms,
        expected_stderr     =>  q{},
        expected_success    =>  0,
        testname            =>  "--help parsed OK",
    });

    # test that testrunner.pl does not parse --help if it comes after --
    test_run({
        args                =>  [ '--', '--help' ],
        expected_stdout     =>  q{},
        expected_stderr     =>  qr{--help: No such file or directory},
        expected_success    =>  0,
        testname            =>  "-- stops argument processing",
    });

    # test that testrunner.pl stops parsing at the first non-option argument
    test_run({
        args                =>  [ '--timeout', '10', 'perl', '--help' ],
        expected_stdout     =>  qr{ ^ Usage: \s+ perl \s }xms,
        expected_stderr     =>  q{},
        expected_success    =>  1,  # perl --help exits successfully
        testname            =>  "parsing stops at first non-option",
    });

    return;
}

sub run
{
    test_arg_parsing;

    test_success;
    test_normal_nonzero_exitcode;
    test_crashing;
    test_hanging;

    done_testing;

    return;
}

run if (!caller);
1;
