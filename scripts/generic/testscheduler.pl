#!/usr/bin/env perl
#############################################################################
##
## Copyright (C) 2015 The Qt Company Ltd.
## Contact: http://www.qt.io/licensing/
##
## This file is part of the Quality Assurance module of the Qt Toolkit.
##
## $QT_BEGIN_LICENSE:LGPL21$
## Commercial License Usage
## Licensees holding valid commercial Qt licenses may use this file in
## accordance with the commercial license agreement provided with the
## Software or, alternatively, in accordance with the terms contained in
## a written agreement between you and The Qt Company. For licensing terms
## and conditions see http://www.qt.io/terms-conditions. For further
## information use the contact form at http://www.qt.io/contact-us.
##
## GNU Lesser General Public License Usage
## Alternatively, this file may be used under the terms of the GNU Lesser
## General Public License version 2.1 or version 3 as published by the Free
## Software Foundation and appearing in the file LICENSE.LGPLv21 and
## LICENSE.LGPLv3 included in the packaging of this file. Please review the
## following information to ensure the GNU Lesser General Public License
## requirements will be met: https://www.gnu.org/licenses/lgpl.html and
## http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
##
## As a special exception, The Qt Company gives you certain additional
## rights. These rights are described in The Qt Company LGPL Exception
## version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
##
## $QT_END_LICENSE$
##
#############################################################################

use 5.010;
use strict;
use warnings;

package QtQA::App::TestScheduler;

=head1 NAME

testscheduler - run a set of autotests

=head1 SYNOPSIS

  # Run all tests mentioned in testplan.txt, up to 4 at a time
  $ ./testscheduler --plan testplan.txt -j4 --timeout 120

Run a set of testcases and output a summary of the results.

=head2 OPTIONS

=over

=item --plan FILENAME (Mandatory)

Execute the test plan from this file.
The test plan should be generated by the "testplanner" command.

=item -j N

=item --jobs N

Execute tests in parallel, up to N concurrently.

Note that only tests marked with parallel_test in the testplan
are permitted to run in parallel.

=item --no-summary

=item --summary

Disable/enable printing a summary of test timing, failures, and
totals at the end of the test run.  Enabled by default.

=item --parallel-stress

Parallel stress testing mode.  This is a special test run mode
to help determine whether or not autotests are parallel-safe.

In this mode, multiple instances of each test are run concurrently,
whether or not they are marked with parallel_test.  If a test fails
when run concurrently, it will be run again by itself.

Any test which fails when run concurrently but passes when run by itself
is considered parallel-unsafe.  All other tests are considered
parallel-safe.

The test scheduler will output a summary of its suggested modifications
to the test configuration.

=item --skip-insignificant

Does not run insignificant tests.

=item --debug

Output a lot of additional information.  Use it for debugging,
when something goes wrong.

=back

All other arguments are passed to the "testrunner" script,
which is invoked once for each test.

=head1 DESCRIPTION

testscheduler runs a set of autotests from a testplan.

testscheduler implements appropriate handling of insignificant
tests and parallel tests according to the metadata in the
testplan (which generally comes from the build system):

=over

=item *

Tests may be run in parallel if they are marked with
parallel_test and testscheduler is invoked with a -j option
higher than 1.

=item *

Test failures may be ignored if a test is marked with insignificant_test.

=back

=cut

use feature 'switch';

use English qw(-no_match_vars);
use Data::Dumper;
use File::Spec::Functions;
use FindBin;
use IO::File;
use Lingua::EN::Inflect qw(inflect);
use List::MoreUtils qw(before after_incl any part);
use List::Util qw(sum max);
use Pod::Usage;
use Readonly;
use Timer::Simple;
use Sys::Hostname;
use Socket;
use IO::Socket::INET;

use Getopt::Long qw(
    GetOptionsFromArray
    :config pass_through bundling
);

# testrunner script
Readonly my $TESTRUNNER => catfile( $FindBin::Bin, 'testrunner.pl' );
Readonly my $BUBAMOUNT => catfile( $FindBin::Bin, 'bubamount.exp' );
Readonly my $BUBAUNMOUNT => catfile( $FindBin::Bin, 'bubaunmount.exp' );
Readonly my $POWERCYCLE => catfile ($FindBin::Bin, 'power_cycle.pl' );
# declarations of static functions
sub timestr;

sub new
{
    my ($class) = @_;

    return bless {
        jobs => 1,
        debug => 0,
        summary => 1,
        skip_insignificant => 0,
    }, $class;
}

sub run
{
    my ($self, @args) = @_;

    GetOptionsFromArray( \@args,
        'help|?'    =>  sub { pod2usage(0) },
        'plan=s'    =>  \$self->{ testplan },
        'j|jobs=i'  =>  \$self->{ jobs },
        'debug'     =>  \$self->{ debug },
        'summary!'  =>  \$self->{ summary },
        'parallel-stress' => \$self->{ parallel_stress },
        'skip-insignificant' => \$self->{ skip_insignificant },
    ) || pod2usage(2);

    # Strip trailing --, if that's what ended our argument processing
    if (@args && $args[0] eq '--') {
        shift @args;
    }

    # All remaining args are for testrunner
    $self->{ testrunner_args } = [ @args ];

    if (!$self->{ testplan }) {
        die "Missing mandatory --plan argument";
    }

    if ( $ENV{ADB_DEVICE_IP} && $ENV{ADB_BIN_DIR} ) {
      my $adb = catfile($ENV{ADB_BIN_DIR},"adb"); 
      my $cmd;
      if ( $ENV{ADB_DEVICE_IP} =~ m/device/i ) {
        $cmd = "$adb devices";
      } else {
        $cmd = "$adb connect $ENV{ADB_DEVICE_IP}";
      }
      print "+ $cmd\n";
      system ($cmd);
      
      # Test if a few second sleep after connect allows for mount to work and device doesn't return 'offline'
      sleep(5);

      # get own ip address
#      my ($addr) = inet_ntoa((gethostbyname(hostname))[4]); #didn't work when dns wasn't updated
      my $sock = IO::Socket::INET->new(PeerAddr => 'www.perl.org',
                                        PeerPort => 'http(80)',
                                        Proto    => 'tcp');

      my $addr = $sock->sockhost;

      # Make sure that /work exists so that it can be mounted to
      $cmd = "$adb shell mkdir /work";
      print "+ $cmd\n";
      system ($cmd);
      # mount own /work to device's /work
      $cmd = "$adb shell mount -t nfs $addr:/work /work";
      print "+ $cmd\n";
      system ($cmd);
    }

    if ( $ENV{SSH_DEVICE_IP} && $ENV{SSH_BIN_DIR} && $ENV{SSHPASS_BIN_DIR} ) {
      # get own ip address
#      my ($addr) = inet_ntoa((gethostbyname(hostname))[4]);
      my $sock = IO::Socket::INET->new(PeerAddr => 'www.perl.org',
                                    PeerPort => 'http(80)',
                                    Proto    => 'tcp');
      my $addr = $sock->sockhost;

#      # Make sure that /work exists so that it can be mounted to
#      my $cmd = "$SSHPASS_BIN -p '$ENV{SSH_DEVICE_PASSWD}' $SSH_BIN $ENV{SSH_DEVICE_USER}\@$ENV{SSH_DEVICE_IP} \"mkdir /work\"";
#      print "+ $cmd\n";
#      system ($cmd);

#      # mount own /work to device's /work
#      $cmd = "$SSHPASS_BIN -p '$ENV{SSH_DEVICE_PASSWD}' $SSH_BIN $ENV{SSH_DEVICE_USER}\@$ENV{SSH_DEVICE_IP} \"mount -t nfs $addr:/work /work\"";
#      print "+ $cmd\n";
#      system ($cmd);

    }

    if ($self->{ parallel_stress } && $self->{ jobs } <= 1) {
        die q{error: --parallel-stress mode doesn't make sense with -j1};
    }

    my @results = $self->do_testplan( $self->{ testplan } );

    $self->debug( sub { 'results: '.Dumper(\@results) } );

    if ($self->{ summary }) {
        # timing info does not make sense in parallel-stress mode
        if ($self->{ parallel_stress }) {
            $self->print_parallel_stress_results( @results );
        } else {
            $self->print_timing( @results );
        }
        $self->print_failures( @results );
        $self->print_totals( @results );
    }

    $self->exit_appropriately( @results );

    return;
}

sub debug
{
    my ($self, $to_print) = @_;

    return unless $self->{ debug };

    my @to_print;
    if (ref($to_print) == 'CODE') {
        @to_print = $to_print->();
    } elsif (ref($to_print) == 'ARRAY') {
        @to_print = @{$to_print};
    } else {
        @to_print = ($to_print);
    }

    my $message = __PACKAGE__ . ": debug: @to_print";
    if ($message !~ m{\n\z}) {
        $message .= "\n";
    }

    warn $message;

    return;
}

sub do_testplan
{
    my ($self, $testplan) = @_;

    my @tests = $self->read_tests_from_testplan( $testplan );

    $self->debug( sub { 'testplan: '.Dumper(\@tests) } );

    # tests are sorted for predictable execution order.
    @tests = sort { $a->{ label } cmp $b->{ label } } @tests;

    local $SIG{ INT } = sub {
        die 'aborting due to SIGINT';
    };

    my @out;

    if ($self->{ parallel_stress }) {
        @out = $self->execute_parallel_stress( @tests );
    } else {
        @out = $self->execute_tests_from_testplan( @tests );
    }

    return @out;
}

sub print_failures
{
    my ($self, @tests) = @_;

    @tests = sort { $a->{ label } cmp $b->{ label } } @tests;

    my @failures = grep { $_->{ _status } } @tests;
    @failures or return;

    # Partition the failures into significant first, then insignificant.
    # Significant failures are shown first because they are, well, more significant :)
    my @parted_failures = part { $_->{ insignificant_test } ? 1 : 0 } @failures;

    print <<'EOF';
=== Failures: ==================================================================
EOF
    foreach my $test (@{ $parted_failures[0] || []}) {
        print "  $test->{ label }\n";
    }
    foreach my $test (@{ $parted_failures[1] || []}) {
        print "  $test->{ label } [insignificant]\n";
    }

    return;
}

sub print_totals
{
    my ($self, @tests) = @_;

    my $total = 0;
    my $pass = 0;
    my $fail = 0;
    my $insignificant_fail = 0;

    foreach my $test (@tests) {
        ++$total;
        if ($test->{ _status } == 0) {
            ++$pass;
        } elsif ($test->{ insignificant_test }) {
            ++$insignificant_fail;
        } else {
            ++$fail;
        }
    }

    my $message = inflect "=== Totals: NO(test,$total), NO(pass,$pass)";
    if ($fail) {
        $message .= inflect ", NO(fail,$fail)";
    }
    if ($insignificant_fail) {
        $message .= inflect ", NO(insignificant fail,$insignificant_fail)";
    }

    $message .= ' ';

    while (length($message) < 80) {
        $message .= '=';
    }

    print "$message\n";

    return;
}

sub print_timing
{
    my ($self, @tests) = @_;

    my $parallel_total = $self->{ parallel_timer }
        ? $self->{ parallel_timer }->elapsed
        : 0;

    my $serial_total = $self->{ serial_timer }->elapsed;
    my $total = $parallel_total + $serial_total;

    # This is the time it would have taken to run the parallel tests
    # if they were not actually run in parallel.
    my $parallel_j1_total = sum( map( {
        ($self->{ jobs } > 1 && $_->{ parallel_test }) ? $_->{ _timer }->elapsed : 0
    } @tests )) || 0;

    # This fudge factor adjusts for the fact that some tests would be able
    # to run faster if they were the only test running.
    # Another way of thinking of this is: by running tests in parallel, we
    # assume we've slowed down individual tests by about 10%.
    if ($self->{ jobs } > 1) {
        $parallel_j1_total *= 0.9;
    }

    # This is the time we estimate we've "wasted" on insignificant tests.
    my $insignificant_total = sum map( {
        if (!$_->{ insignificant_test }) {
            0;
        } elsif ($_->{ _parallel_count}) {
            $_->{ _timer }->elapsed / $_->{ _parallel_count };
        } else {
            $_->{ _timer }->elapsed;
        }
    } @tests );

    my $parallel_speedup = $parallel_j1_total - $parallel_total;

    if ($parallel_total) {

        printf( <<'EOF',
=== Timing: =================== TEST RUN COMPLETED! ============================
  Total:                                       %s
  Serial tests:                                %s
  Parallel tests:                              %s
  Estimated time spent on insignificant tests: %s
  Estimated time saved by -j%d:                 %s
EOF
            timestr( $total ),
            timestr( $serial_total ),
            timestr( $parallel_total ),
            timestr( $insignificant_total ),
            $self->{ jobs },
            timestr( $parallel_speedup ),
        );

    } else {

        printf( <<'EOF',
=== Timing: =================== TEST RUN COMPLETED! ============================
  Total:                                       %s
  Estimated time spent on insignificant tests: %s
EOF
            timestr( $total ),
            timestr( $insignificant_total ),
        );

    }

    return;
}

sub print_parallel_stress_results
{
    my ($self, @tests) = @_;

    @tests = sort { $a->{ label } cmp $b->{ label } } @tests;

    # test passed when run concurrently: parallel-safe
    my @parallel_safe = grep { $_->{ _status_parallel } == 0 } @tests;

    # test failed when run concurrently, passed when run serially: parallel-unsafe
    my @parallel_unsafe = grep { $_->{ _status_parallel } != 0 && $_->{ _status_serial } == 0 } @tests;

    # test failed concurrently and serially: no comment can be made on its parallel safety.
    my @unknown = grep { $_->{ _status_serial } } @tests;

    print "=== Parallel stress test: ======================================================\n";

    local $LIST_SEPARATOR = "\n    ";

    my $modify_count = 0;

    # parallel-safe but not marked as such?
    if (my @add_parallel_test = grep { !$_->{ parallel_test } } @parallel_safe) {
        my @tests_to_modify = map { $_->{ label } } @add_parallel_test;
        $modify_count += @tests_to_modify;
        print "  Suggest adding CONFIG+=parallel_test to these:\n    @tests_to_modify\n";
    }

    # parallel-unsafe but marked as parallel-safe?
    if (my @remove_parallel_test = grep { $_->{ parallel_test } } @parallel_unsafe) {
        my @tests_to_modify = map { $_->{ label } } @remove_parallel_test;
        $modify_count += @tests_to_modify;
        print "  Suggest removing CONFIG+=parallel_test from these:\n    @tests_to_modify\n";
    }

    my $safe_count = @parallel_safe;
    my $unsafe_count = @parallel_unsafe;
    my $unknown_count = @unknown;

    my $message = "=== $safe_count parallel-safe, $unsafe_count parallel-unsafe, "
                 ."$unknown_count unknown, $modify_count to modify";

    $message .= ' ';

    while (length($message) < 80) {
        $message .= '=';
    }

    print "$message\n";

    return;
}

sub read_tests_from_testplan
{
    my ($self, $testplan) = @_;

    my @tests;

    my $fh = IO::File->new( $testplan, '<' ) || die "open $testplan for read: $!";
    my $line_no = 0;
    while (my $line = <$fh>) {
        ++$line_no;
        my $test = eval $line;  ## no critic (ProhibitStringyEval)
        if (my $error = $@) {
            die "$testplan:$line_no: error: $error";
        }
        if (!$test->{ insignificant_test } || !$self->{ skip_insignificant }) {
            push @tests, $test;
        }
    }

    return @tests;
}

sub execute_tests_from_testplan
{
    my ($self, @tests) = @_;

    my $jobs = $self->{ jobs };

    # Results will be recorded here.
    # Each element is equal to an input element from @tests with additional keys added.
    # Any keys added from testscheduler start with an '_' so they won't clash with
    # keys from the testplan.
    #
    # Result keys include:
    #   _status         =>  exit status of test
    #   _parallel_count =>  amount of tests still running at the time this test completed
    #   _parallel_tests =>  list of all tests which have run concurrently with this one
    #                       (approximately in the order they were run)
    #   _timer          =>  Timer::Simple object for this test's runtime
    #
    $self->{ test_results } = [];

    # Do all the parallel tests first, then serial.
    # However, if jobs are 1, all tests are serial.
    my @parallel_tests;
    my @serial_tests;
    foreach my $test (@tests) {
        if ($test->{ parallel_test } && $jobs > 1) {
            push @parallel_tests, $test;
        }
        else {
            push @serial_tests, $test;
        }
    }

    # If there is only one parallel test, downgrade it to a serial test
    if (@parallel_tests == 1) {
        @serial_tests = (@parallel_tests, @serial_tests);
        @parallel_tests = ();
    }

    if (@parallel_tests) {
        $self->{ parallel_timer } = Timer::Simple->new( );
        $self->execute_parallel_tests( @parallel_tests );
        $self->{ parallel_timer }->stop( );
    }

    if (@parallel_tests && @serial_tests) {
        my $p = scalar( @parallel_tests );
        my $s = scalar( @serial_tests );
        # NO -> Number Of
        $self->print_info( inflect "ran NO(parallel test,$p).  Starting NO(serial test,$s).\n" );
    }

    $self->{ serial_timer } = Timer::Simple->new( );
    $self->execute_serial_tests( @serial_tests );
    $self->{ serial_timer }->stop( );

    my @test_results = @{ $self->{ test_results } };

    # Sanity check
    if (scalar(@test_results) != scalar(@tests)) {
        die 'internal error: I expected to run '.scalar(@tests).' tests, but only '
           .scalar(@test_results).' tests reported results';
    }

    return @test_results;
}

# Do parallel stress test.
# Compared to normal execution, the following additional result keys are
# associated with each test:
#
#  _status_parallel => (worst) exit status of the test when run in parallel
#  _status_serial   => exit status of the test when run in serial (unset if
#                      _status_parallel is 0)
#
sub execute_parallel_stress
{
    my ($self, @tests) = @_;
    return unless @tests;

    my @all_tests = @tests;
    my @failed_tests;

    my $j = $self->{ jobs };

    while (my $test = shift @all_tests) {
        my @status;

        # Run each test a total of $j*2 times, maximum of $j times concurrently.
        for (my $i = 0; $i < 2*$j; ++$i) {
            while ($self->running_tests_count() > $j) {
                my $status = $self->wait_for_test_to_complete( );
                if (defined( $status )) {
                    push @status, $status;
                }
            }
            $self->spawn_subtest(
                test => $test,
                testrunner_args => [ '--sync-output' ],
            );
        }

        # Then wait for them all to complete.
        while ($self->running_tests_count()) {
            my $status = $self->wait_for_test_to_complete( );
            if (defined( $status )) {
                push @status, $status;
            }
        }

        my $worst_status = max @status;

        $test->{ _status_parallel } = $worst_status;

        if ($worst_status) {
            # If the test (ever) failed, we'll run it again serially later,
            # and make sure _status reflects the failure (rather than being set to the status
            # of whichever process happened to finish last).
            push @failed_tests, $test;
            $test->{ _status } = $worst_status;
        }
    }

    if (my $count = @failed_tests) {
        $self->print_info( "parallel-stress: running $count failed tests again, in serial\n" );
    }

    # We've run all tests in parallel, now run all failed tests again, serially.
    while (my $test = shift @failed_tests) {
        $self->spawn_subtest(
            test => $test,
            testrunner_args => [ '--sync-output' ],
        );
        while ($self->running_tests_count()) {
            if (defined(my $status = $self->wait_for_test_to_complete( ))) {
                $test->{ _status_serial } = $status;
            }
        }
    }

    return @tests;
}

sub execute_parallel_tests
{
    my ($self, @tests) = @_;
    return unless @tests;

    while (my $test = shift @tests) {
        while ($self->running_tests_count() >= $self->{ jobs }) {
            $self->wait_for_test_to_complete( );
        }
        $self->spawn_subtest(
            test => $test,
            testrunner_args => [ '--sync-output' ],
        );
    }

    while ($self->running_tests_count()) {
        $self->wait_for_test_to_complete( );
    }

    return;
}

sub execute_serial_tests
{
    my ($self, @tests) = @_;

    return unless @tests;

    while (my $test = shift @tests) {
        while ($self->running_tests_count()) {
            $self->wait_for_test_to_complete( );
        }
        if ($ENV{SSH_DEVICE_USER} && $ENV{SSH_DEVICE_PASSWD} && $ENV{SSH_DEVICE_IP}) {
            my $sock = IO::Socket::INET->new(PeerAddr => 'www.perl.org',
                                    PeerPort => 'http(80)',
                                    Proto    => 'tcp');
            my $addr = $sock->sockhost;

            if (defined $ENV{POWER_SWITCH_IP} and ($ENV{POWER_SWITCH_IP} ne "")) {
                print "Rebooting device at IP '$ENV{POWER_SWITCH_IP}'\n";
                print "+ $POWERCYCLE --rebootandwait\n";
                system ("$POWERCYCLE --rebootandwait");
            }
            print "Mounting host to device\n";
            system ("$BUBAMOUNT $ENV{SSH_DEVICE_USER} $ENV{SSH_DEVICE_PASSWD} $ENV{SSH_DEVICE_IP} $addr");

            $self->spawn_subtest( test => $test );

#            print "Unmounting host from device\n";
#            system ("$BUBAUNMOUNT $ENV{SSH_DEVICE_USER} $ENV{SSH_DEVICE_PASSWD} $ENV{SSH_DEVICE_IP} $addr");
        } else {
            $self->spawn_subtest( test => $test );
        }
    }

    while ($self->running_tests_count()) {
        $self->wait_for_test_to_complete( );
    }

    return;
}

sub print_info
{
    my ($self, $info) = @_;

    local $| = 1;
    print __PACKAGE__.': '.$info;

    return;
}

# Returns a list of any additional testrunner args for the given $test,
# based on its metadata.  May return an empty list.
sub testrunner_args_for_test
{
    my ($self, $test) = @_;

    my $label = $test->{ label };

    my @out;

    if (my $timeout = $test->{ 'testcase.timeout' }) {
        if ($timeout =~ m{\A [0-9]+ \z}xms) {
            push @out, ('--timeout', $timeout);
        } else {
            $self->print_info( "$label: ignored invalid testcase.timeout value of \"$timeout\"\n" );
        }
    }

    push @out, ('--label', $label);

    return @out;
}

sub spawn_subtest
{
    my ($self, %args) = @_;

    my $test = $args{ test };

    my @testrunner_args = (
        '--chdir',
        $test->{ cwd },
        @{ $args{ testrunner_args } || []},
        @{ $self->{ testrunner_args } || []},
    );

    push @testrunner_args, $self->testrunner_args_for_test( $test );

    my @cmd_and_args = @{ $test->{ args } };

    my @testrunner_cmd = (
        $EXECUTABLE_NAME,
        $TESTRUNNER,
        @testrunner_args,
    );

    my @cmd = (@testrunner_cmd, '--', @cmd_and_args );
    $test->{ _timer } = Timer::Simple->new( );

    # Save a reference to all tests running at the time this test began,
    # and also associate this test we've started with all other currently running tests
    $test->{ _parallel_tests } = [];
    foreach my $other_pid (keys %{ $self->{ test_by_pid } || {} }) {
        my $other_test = $self->{ test_by_pid }{ $other_pid };
        push @{ $test->{ _parallel_tests } }, $other_test;
        push @{ $other_test->{ _parallel_tests } }, $test;
    }

    my $pid = $self->spawn( @cmd );
    $self->{ test_by_pid }{ $pid } = $test;

    return;
}

sub running_tests_count
{
    my ($self) = @_;

    my $out = scalar keys %{ $self->{ test_by_pid } || {} };

    $self->debug( "$out test(s) currently running" );

    return $out;
}

# Waits for one test to complete and writes the '_status' key for that test.
# The exit status is returned.
sub wait_for_test_to_complete
{
    my ($self, $flags) = @_;

    return if (!$self->running_tests_count( ));

    my $pid = waitpid( -1, $flags || 0 );
    my $status = $?;

    $self->debug( sprintf( "waitpid: (pid: %d, status: %d, exitcode: %d)", $pid, $status, $status >> 8) );

    if ($pid <= 0) {
        # this means no child processes
        return;
    }

    my $test = delete $self->{ test_by_pid }{ $pid };
    if (!$test) {
        warn "waitpid returned $pid; this pid could not be associated with any running test";
        return;
    }

    $test->{ _timer }->stop( );
    $test->{ _status } = $status;
    $test->{ _parallel_count } = $self->running_tests_count( );

    $self->print_test_fail_info( $test );

    push @{ $self->{ test_results } }, $test;

    return $status;
}

sub print_test_fail_info
{
    my ($self, $test) = @_;

    if ($test->{ _status } == 0) {
        return;
    }

    my $msg = "$test->{ label } failed";
    if ($test->{ insignificant_test }) {
        $msg .= ', but it is marked with insignificant_test';
    }

    # dump the list of tests run concurrently with this one; it can
    # be relevant for debugging failures from parallel tests.
    if (my @other_tests = @{ $test->{ _parallel_tests } || []}) {
        local $LIST_SEPARATOR = ', ';
        my @labels = map { $_->{ label } } @other_tests;

        # We might have run in parallel with _many_ other tests.
        # This can make the output unacceptably large.  Limit it a bit.
        my $MAX_LABELS = 8;
        if (@labels > $MAX_LABELS) {
            # Replace the inner $omit_count tests with a "tests omitted" bit of text,
            # because the first and last run tests are the most valuable information.
            # Note: the +1 here is because the "omitted" text itself takes up 1 label.
            my $omit_count = (@labels - $MAX_LABELS) + 1;
            splice( @labels, $MAX_LABELS/2, $omit_count, inflect( "[NO(other test,$omit_count)]" ) );
        }

        $msg .= "; run concurrently with @labels";
    }

    $self->print_info( "$msg\n" );

    return;
}

sub spawn
{
    my ($self, @cmd) = @_;

    my $pid;

    if ($OSNAME =~ m{win32}i) {
        # see `perldoc perlport'
        $pid = system( 1, @cmd );
    } else {
        $pid = fork();
        if ($pid == -1) {
            die "fork: $!";
        }
        if ($pid == 0) {
            exec( @cmd );
            die "exec: $!";
        }
    }

    $self->debug( sub { "spawned $pid <- ".join(' ', map { "[$_]" } @cmd) } );

    return $pid;
}

sub exit_appropriately
{
    my ($self, @tests) = @_;

    my $fail = any { $_->{ _status } && !$_->{ insignificant_test } } @tests;

    exit( $fail ? 1 : 0 );
}

#======= static functions =========================================================================

# Given an interval of time in seconds, returns a human-readable string
# using the units a reader would most likely prefer to see;
# e.g.
#
#    timestr(12345) -> '3 hours 25 minutes'
#    timestr(123)   -> '2 minutes 3 seconds'
#
sub timestr
{
    my ($seconds) = @_;

    if (!$seconds) {
        return '(no time)';
    }

    $seconds = int($seconds);

    if (!$seconds) {
        # Not zero before truncation to int,
        # but now it is zero; then, an almost-zero time
        return '< 1 second';
    }

    my $hours;
    my $minutes;

    if ($seconds > 60*60) {
        $hours = int($seconds/60/60);
        $seconds -= $hours*60*60;

        $minutes = int($seconds/60);
        $seconds = 0;
    } elsif ($seconds > 60) {
        $minutes = int($seconds/60);
        $seconds -= $minutes*60;
    }

    my @out;
    if ($hours) {
        push @out, inflect( "NO(hour,$hours)" );
    }
    if ($minutes) {
        push @out, inflect( "NO(minute,$minutes)" );
    }
    if ($seconds) {
        push @out, inflect( "NO(second,$seconds)" );
    }

    return "@out";
}

#==================================================================================================

QtQA::App::TestScheduler->new( )->run( @ARGV ) if (!caller);
1;
