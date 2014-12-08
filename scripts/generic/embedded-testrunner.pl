#!/usr/bin/perl -w

use strict;
use warnings;
use Cwd;
use Cwd qw(abs_path);
use File::Basename;
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use File::Spec;
use Getopt::Long;
use Pod::Usage;
use QMake::Project;
use Time::Out qw(timeout) ;
use Time::HiRes qw(time);


# android configurables
my $android_sdk_dir = "$ENV{'ANDROID_SDK_ROOT'}" if (defined $ENV{'ANDROID_SDK_ROOT'});
my $android_ndk_dir = "$ENV{'ANDROID_NDK_ROOT'}" if (defined $ENV{'ANDROID_NDK_ROOT'});
my $android_to_connect = "$ENV{'ANDROID_DEVICE'}"  if (defined $ENV{'ANDROID_DEVICE'});

# Android constants
my $android_temp_dir = "_tst_runner_temp_dir";

# common configurables
my $build_dir = ".";
my $qt_bin_dir = "";
my $log_out = "txt";
my $max_runtime = 1;
my $build_test = 1;
my $platform = "Android";
my $verbose = 0;

# Common constants
my @stack = cwd;
my $man = 0;
my $help = 0;
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
my $output_dir = File::Spec->catdir($stack[0]."/".(1900+$year)."-$mon-$mday-$hour:$min");
my @failures = '';
my $total_tests = 0;
my $total_failed = 0;
my $failed_insignificants = 0;
my $start = time();
my $nix_utils = "";

GetOptions('h|help' => sub { pod2usage(1) }
            , 'b|bdir=s' => \$build_dir
            , 'q|qdir=s' => \$qt_bin_dir
            , 'v|verbose' => sub { $verbose = 1 }
            , 'sdk=s' => \$android_sdk_dir
            , 'ndk=s' => \$android_ndk_dir
            , 'logtype=s' => \$log_out
            , 'runtime=i' => \$max_runtime
            , 'platform=s' => \$platform
            , 'build=i' => \$build_test
            , 'no-build' => sub { $build_test = 0 }
            , 'nix_utils_dir=s' => \$nix_utils
            ) or pod2usage(1);

my $adb_tool = "$android_sdk_dir/platform-tools/adb" if (defined $android_sdk_dir);
#my $SED = ($nix_utils eq "")? "sed" : "$nix_utils\\sed";
#my $CAT = ($nix_utils eq "")? "cat" : "$nix_utils\\cat";
#my $CUT = ($nix_utils eq "")? "cut" : "$nix_utils\\cut";
#my $TAIL = ($nix_utils eq "")? "tail" : "$nix_utils\\head";
#my $HEAD = ($nix_utils eq "")? "head" : "$nix_utils\\tail";
set_platform_casing();
my $path = $ENV{'PATH'};
local $ENV{'PATH'} = "$nix_utils;$qt_bin_dir;$path" if ( $platform eq "WinRT");
system("set") if ( $platform eq "WinRT");

# Helper to unix commands to win counterparts. Finding ssh commands
# from Windows Git bin directory
sub get_win_command
{
    my $stage = shift;
    my $cmd = shift;
    my $key = shift;

    if($key){
      $key = " -i ";
      $key .= catfile($ENV{HOMEPATH}, ".ssh", "id_rsa");
    } else {
      $key ="";
    }

    if ($stage =~ "win32") {
        return "copy" if ( $cmd eq "cp");
        my $git_path = qx("where git");
        print "GIT POLKU $git_path \n";
        my @path = split(/\\/, $git_path );
        $path[-2]="bin";
        $cmd .= ".exe";
        $path[-1]=$cmd;
        $cmd = join('\\',@path);
        $cmd = "\"$cmd\" $key";
        print "CMD POLKU $cmd \n";
    }
    return $cmd;
}

#my $SED = ($nix_utils eq "")? "sed" : "$nix_utils\\sed";
#my $CAT = ($nix_utils eq "")? "cat" : "$nix_utils\\cat";
#my $CUT = ($nix_utils eq "")? "cut" : "$nix_utils\\cut";
#my $TAIL = ($nix_utils eq "")? "tail" : "$nix_utils\\head";
#my $HEAD = ($nix_utils eq "")? "head" : "$nix_utils\\tail";

###############################
### Directory utilities 
###############################

sub dir
{
    if ( $platform eq "WinRT") {
        system ("cd") if ($verbose);
    } else {
        system("pwd") if ($verbose);
    }
}

sub pushd ($)
{
    unless ( chdir $_[0] )
    {
        warn "Error: $!\n";
        return;
    }
    unshift @stack, cwd;
    dir();
}

sub popd ()
{
    @stack > 1 and shift @stack;
    chdir $stack[0];
    dir();
}


###############################
# Build the tests if needed
###############################
sub build_tests
{
    # The purpose is to get rid of this once the CI is capable of building all tests.
    # Only purpose for this is to get something to test.
    pushd($build_dir);
    system ("cp $qt_bin_dir/../tests/auto/android/AndroidManifest.xml $qt_bin_dir/"); #TODO find path properly
    system ("cp $qt_bin_dir/../tests/auto/android/AndroidManifest.xml $build_dir/"); #TODO find path properly
    system("$qt_bin_dir/qmake -r") == 0 or warn "Can't run qmake\n"; 
    system("make -k") == 0 or warn "Can't build all tests\n"; 
}

###############################
# Beautify the given platform
# argument. Set casing for nice
# printouts.
###############################
sub set_platform_casing
{
    $platform = "Android" if ($platform =~ m/^android$/i);
    $platform = "IOS" if ($platform =~ m/^ios/i);
    $platform = "WinRT" if ($platform =~ m/^winrt/i);
}
###############################
# Find the cases to be run
###############################

sub find_tests
{
    my @test_cases = "";
    my $cmd ="";
    pushd($build_dir);
    if ($platform eq "IOS") {
        $cmd = "find . -name tst_*.app";
        @test_cases = qx(${cmd});
    } elsif ($platform eq "Android") {
        $cmd = "find . -name $android_temp_dir";
        my @tmp_dir = qx(${cmd});
        foreach my $td (@tmp_dir) {
            print "trying to remove $td\n" if ($verbose);
            system("rm -rf $td");
        }
        $cmd = "find . -name libtst_*.so";
        @test_cases = qx(${cmd});
    } elsif ($platform eq "WinRT") {
        $cmd = "dir /S/B tst_*.exe";
        @test_cases = qx(${cmd});
    }

    print "Running following test cases:\n";
    foreach my $tc (@test_cases) {
        print "    $platform testplan: ".basename($tc);
    }
    return @test_cases;
}

###############################
# Clean installed applications 
###############################

sub clean_ios_tests
{
    print "Cleaning up old tests\n";
    my $cmd = "rm -rf ~/\"Library/Application\ Support/iPhone\ Simulator\"/**/Applications/";
    my $_log = qx(${cmd});
    print "$_log";# if($verbose);
}


###############################
# Connect to Android tablet
###############################
sub android_connect
{
    if ($android_to_connect eq "") {
        print "Error: Can't find device to connect\n";
        return 0;        
    }
    print " Found device to be connected from env: $android_to_connect \n";
    #system("ssh dev-ubuntu1204-x64-01.ci.local -L 5555:10.99.112.12:5555 -N &");
    $android_to_connect="10.99.112.12";
    system("$adb_tool disconnect $android_to_connect");
    system("$adb_tool connect $android_to_connect");
    sleep(2);# let it connect
    system("$adb_tool -s $android_to_connect reboot &");# adb bug, it blocks forever
    sleep(15); # wait for the device to come up again
    system("$adb_tool disconnect $android_to_connect");
    system("$adb_tool connect $android_to_connect");

    return 1;
}



###############################
# Parse the output log and return
# failure if needed.
###############################
sub print_output
{
    my $res_file = shift;
    my $case = shift;
    my $insignificant = shift;
    print "Got output file $res_file \n" if ($verbose);
    my $print_all = 0;
    if (-e $res_file) {
        open my $file, $res_file or die "Could not open $res_file: $!";
        while (my $line = <$file>) {
            if ($line =~ m/^FAIL/) {
                print "$line";
                $print_all = 1;
            }
        }
        close $file;
        if ($print_all) {
                    my $cmd="cat ${res_file}";
                    print qx(${cmd});
            if ($insignificant) {
                print " Testrunner: $case failed, but it is marked with insignificant_test\n";
                push (@failures ,(basename($case)." [insignificant]")); 
                $failed_insignificants=$failed_insignificants+1;
            } else {
                $total_failed++;
                push (@failures ,(basename($case))); 
            }
        } else {
            my $cmd = "tail -2 ${res_file} | head -1";
            #my $cmd = "sed -n 'x;\$p' ${res_file}";
            my $summary = qx(${cmd});
            if ($summary =~ m/^Totals/) {
                print "$summary";
            } else {
                print "Error: The log is incomplete. Looks like you have to increase the timeout."; 
                if ($insignificant) {
                    print " Testrunner: $case failed, but it is marked with insignificant_test\n";
                    push (@failures ,(basename($case)." [insignificant]"));
                    $failed_insignificants = $failed_insignificants+1;
                } else {
                    $total_failed++;
                    push (@failures ,(basename($case)));
                }
            }
        }
    } else { # Couldn't find the log file
        if ($insignificant) {
            print " Failed to execute $case, but it is marked with insignificant_test\n";
            push (@failures ,(basename($case)." [insignificant]")); 
            $failed_insignificants=$failed_insignificants+1;
        } else {
            print "Failed to execute $case \n";
            $total_failed++;
            push (@failures ,(basename($case)));
        }
    }
}

##############################
# Print summary of test run
##############################

sub print_summary
{
    my $total = time()-$start;
    my $h = 0;
    my $m = 0;
    my $s = 0;
    my $exit = 0;
    print "=== Timing: =================== TEST RUN COMPLETED! ============================\n";
    if ($total > 60*60) {
        $h = int($total/60/60);
        $s = int($total - $h*60*60);

        $m = int($s/60);
        $s = 0;
        print "Total:                                       $h hours $m minutes\n";
    } elsif ($total > 60) {
        $m = int($total/60);
        $s = int($total - $m*60);
        print "Total:                                       $m minutes $s seconds\n";
    } else {
        $s = int($total);
        print "Total:                                       $s seconds\n";       
    }

    print "=== Failures: ==================================================================";
    foreach my $failed (@failures) {
        print $failed."\n";
        $exit = 1;
    }  
    print "=== Totals: ".$total_tests." tests, ".($total_tests-$total_failed).
          " passes, ".$failed_insignificants.
          " insignificant fails ======================\n";
    return $exit;
}

###############################
# Android specific timeout. We
# can't just  timeout the system
# while we are running in remote
# device.
###############################

sub wait_for_process
{
    my $process = shift;
    my $action = shift;
    my $timeout = shift;   # max_runtime
    my $device_serial = $android_to_connect ;
    $timeout = $timeout*60;  #secs
    my $sleepPeriod = 5;
    $sleepPeriod = 1 if !defined($sleepPeriod);
    print "Waiting for $process ".$timeout." seconds to" if ($verbose);
    print $action?" start...\n":" die...\n" if ($verbose);
    while ($timeout--) {
        my $output = `$adb_tool -s $device_serial shell ps 2>&1`; # get current processes
        #FIXME check why $output is not matching m/.*S $process\n/ or m/.*S $process$/ (eol)
        my $res = ($output =~ m/.*S $process/)?1:0; # check the procress
        if ($action == $res) {
            print "... succeed\n" if ($verbose);
            return 0;
        }
        sleep($sleepPeriod);
        $timeout = $timeout-($sleepPeriod-1);
        print "timeount in ".$timeout." seconds\n" if ($verbose);
    }
    print "... failed\n" if ($verbose);
    return -1;
}

###############################
# Install Android test locally
# and deploy.
###############################

sub run_android_test
{
    my $case = shift;
    my $insignificant = shift;
    my $device_serial = $android_to_connect ;
    my $tst = abs_path(dirname($case));
    pushd(abs_path(dirname($case)));
    my $app = basename($case);
    my $output = File::Spec->catfile( $app."_results" );
    my $cmd = "make INSTALL_ROOT=${android_temp_dir} install 2>&1";
    my $_log = qx(${cmd});
    print $_log if($verbose);
    $cmd = "${qt_bin_dir}/androiddeployqt --install".
                                        " --device ${device_serial}".
                                        " --output ${android_temp_dir}".
                                        " --deployment debug".
                                     " --verbose".
                                     " --input android-$app-deployment-settings.json".
                                     " 2>&1";
    $_log = qx(${cmd});
    print $_log if($verbose);
    start_android_test($app, $output, $insignificant) or warn "Can't run $app ...\n";
    popd();
}


###############################
# Run IOS test in Simulator
###############################

sub run_ios_test
{
    my $case = shift;
    my $insignificant = shift;
    if ($insignificant) {
        print " DBG Still insignificant \n";
    } else {
        print " DBG not insignificant \n";
    }
    unlink("output.txt");
    unlink("errors.txt");
    sleep(2); # I have to give it a time to exit the previous app

    my $cmd = "ios-sim launch ${case} --stdout output.txt".
                                  " --stderr errors.txt".
                                  " --timeout 60 2>&1";
    my $kill_cmd = "killall -v \"iPhone Simulator\"";
    my $runtime = $max_runtime*60;
    my $ios_ret = "";
    timeout $runtime => sub {
        $ios_ret = qx(${cmd});
    };
    print "DBG: RAN $cmd \n";
    print "DBG: $ios_ret\n";
    if ($@) {
        print "Timed out .....$@) \n";
        if ($insignificant) {
            print " Testrunner: $case failed, but it is marked with insignificant_test\n";
            push (@failures ,(basename($case)." [insignificant]")); 
            $failed_insignificants=$failed_insignificants+1;
        } else {
                   print "It was significant...\n";
                $total_failed++;
                push (@failures ,(basename($case))); 
        }

    } else {
        # check if the ios-sim itself fails to launch to app
        my $print_all = 0;
        if (index($ios_ret, "failed") != -1) {
            print "     ios-sim failure!, re-running\n";
            qx{${kill_cmd}};
            unlink("output.txt");
            timeout $runtime => sub {
                $ios_ret = qx(${cmd});
            };
            if ($@) {
                print "Timed out while re-running..... \n";
                qx{${kill_cmd}};
            } else {
                if (-z 'output.txt') {
                    print "     Unable to execute $case, re-starting simulator\n";
                    qx{${kill_cmd}};
                }
            }
        }
        print_output("output.txt", $case, $insignificant);
    }
}

#################
# Run WinRT test
#################

sub run_winrt_test
{
    my $case = shift;
    my $insignificant = shift;
    unlink("output.txt");
    unlink("errors.txt");
    sleep(2); # I have to give it a time to exit the previous app
    my $deploy = "windeployqt ${case} --no-translations";
    my $runtime = $max_runtime*60;
    my $winrt_ret = qx(${deploy});
    print $winrt_ret if ($verbose);
    # TODO: fix once winrt runner passes -o file.txt,txt args to test
    my $output =basename($case);
    $output = (split('\.', $output))[0];
    $output .="_output.txt";

    print "The tesresult file name is expected to be as $output \n";

    #my $run_test = "winrtrunner -start -wait 0 -remove -verbose 0 ${case} -o output.xml,xml -o output.txt,txt";
    my $run_test = "winrtrunner ${case}";
    timeout $runtime => sub {
        print "Running test and waiting for $runtime secs\n";
        $winrt_ret = qx(${run_test});
        print $winrt_ret if ($verbose);
    };

    if ($@) {
        print "Timed out .....: : $@ \n";
        # Still print the output, while the runner tends to get stucked
        print_output($output, $case, $insignificant);
    } else {
        print_output($output, $case, $insignificant);
    }
}

###############################
# Copy and launch the Android 
# test in remote device.
###############################

sub start_android_test
{
    my $testName = shift;
    my $cmd = "echo ${testName} | cut -d_ -f2 | cut -d. -f1";
    #print "" if ($verbose);
    $testName = qx(${cmd});
    $testName =~ s/\R//g;
    my $packageName = "org.qtproject.example.tst_$testName";
    my $intentName = "$packageName/org.qtproject.qt5.android.bindings.QtActivity";
    my $output_file = shift;
    my $insignificant = shift;
    my $device_serial = $android_to_connect ;
    my $get_xml = 0;
    my $get_txt = 0;
    my $testLib = "";
    if ($log_out eq "xml") {
        $testLib = "-o /data/data/$packageName/output.xml,xml";
        $get_xml = 1;
    } elsif ($log_out eq "txt") {
        $testLib = "-o /data/data/$packageName/output.txt,txt";
        $get_txt = 1;
    } else {
        $testLib = "-o /data/data/$packageName/output.xml,xml -o /data/data/$packageName/output.txt,txt";
        $get_xml = 1;
        $get_txt = 1;
    }

    $cmd = "$adb_tool -s ${device_serial} shell am start".
                  " -e applicationArguments \"${testLib}\"". 
                  " -n ${intentName} 2>&1";
    my $_log = qx(${cmd});
    print "$_log" if ($verbose);
    #wait to start (if it has not started and quit already)
    wait_for_process($packageName,1,1);

    #wait to stop
    unless(wait_for_process($packageName,0,$max_runtime)) {
        #killProcess($packageName);
        print "Someone should kill $packageName\n";
    }
    if ($get_xml) {
        $cmd = "${adb_tool} -s ${device_serial} pull /data/data/$packageName/output.xml ".
                             "${output_dir}/${output_file}.xml";
        $_log = qx(${cmd});
        print "$_log" if ($verbose);
    }
    if ($get_txt) {
        $cmd = "${adb_tool} -s ${device_serial} pull /data/data/$packageName/output.txt ".
                            "${output_dir}/${output_file}.txt 2>&1";
        $_log = qx(${cmd});
        print "$_log" if ($verbose);
        print_output("${output_dir}/${output_file}.txt", $testName, $insignificant);
    }
    return 1;
}

##############################
# Read possible insignificance
# from pro file
##############################
sub check_if_insignificant
{
    return 0 if ($platform eq "WinRT");
    print "Checking if insignificant\n" if ($verbose);
    print "In DIR : " if ($verbose);
    dir() if ($verbose);
    print "\n" if ($verbose);
    my $case = shift;
    my $platform = shift;
    my $insignificant = 0;
    if ($platform eq "IOS" || $platform eq "WinRT") {
        pushd(abs_path(File::Spec->catdir(dirname($case))."/../"));
        if ($platform eq "IOS") {
            system("ls -l");
        } else {
            system("dir");
        }
    } else {
        pushd(abs_path(dirname($case)));
    }
    print "In DIR after platform detect: " if ($verbose);
    dir() if ($verbose);
    print "\n" if ($verbose);
    my $prj = QMake::Project->new( 'Makefile' ) if ($platform ne "WinRT");
    $prj = QMake::Project->new( 'Makefile.Release' ) if ($platform eq "WinRT");
    #my $testcase = $prj->test( 'testcase' );
    $insignificant = $prj->test( 'insignificant_test' );
    print "In DIR after insignificance check $insignificant" if ($verbose);
    dir() if ($verbose);
    print "\n" if ($verbose);
    popd();
    return $insignificant;
}

###############################
# Go trough each test found 
# recursively under the defined
# build directory.
###############################
sub run
{
   # set_platform_casing();
    mkdir($output_dir);
    unlink("latest");
    system("ln -s $output_dir latest") if ($platform eq "Android");
    
    build_tests() if ($build_test);
    if ($platform eq "Android")
    {
        exit (1) if (!android_connect());
    } elsif ($platform eq "IOS"){
        clean_ios_tests();
    } elsif ($platform eq "WinRT"){
        print "getting win tools to $qt_bin_dir \n";
        my $CURL =  get_win_command("win32", "curl", "");
        my $ target_dir = $qt_bin_dir;
        $target_dir =~s/\\/\//g;
        print "Command is $CURL\n";
        my $get_windeployqt = "curl http://testresults.qt-project.org/ci/artifacts/winrt/windeployqt.exe -o $target_dir\\windeployqt.exe";
        my $get_winrtrunner = "curl http://testresults.qt-project.org/ci/artifacts/winrt/winrtrunner.exe -o $target_dir\\winrtrunner.exe";
        my $_log = qx(${get_windeployqt});
        print "WINDEPLOY: $_log \n";
        $_log = qx(${get_winrtrunner});
        print "WINRTRUNNER: $_log \n";
    }

    my @test_cases = find_tests();
    foreach my $case (@test_cases){
        $total_tests = $total_tests+1;
        $case =~ s/\R//g;
        print "$platform TestRunner: begin ".basename($case)."\n";
        my $insignificant = check_if_insignificant($case, $platform);
        print "                -> test $case was set as I== $insignificant ==\n";
        if ($platform eq "Android") {
            run_android_test($case, $insignificant);
        } elsif ($platform eq "IOS") {
            #$case = "Release-iphoneos/".basename($case);
            run_ios_test($case, $insignificant);
        } elsif ($platform eq "WinRT") {
            run_winrt_test($case, $insignificant);
        } else {
             die "Unknown platform : $platform";
        } #platform
        print "$platform TestRunner: end ".basename($case)."\n";
    }
    exit (print_summary());
}
run() unless caller;

__END__

=head1 NAME

Script to run all qt tests in non-desktop device, Currently supported devices are
IOS and Android (default).

=head1 SYNOPSIS

runtests.pl [options]

=head1 OPTIONS

=item B<-platform = Android|IOS>

Target platform. Default is Android, which IP address is expected to be found from
ANDROID_DEVICE env variable.

=item B<-b /build/dir>

Root folder of all tests to be run. If left empty, tests are expected to be built.

=item B<-q path/to/qt bin directory>

Path to exiting qmake etc.

=item B<-v>

Enables some verbose output from external tools.

=item B<-sdk /path/to/Android/SDK>

=item B<-ndk = /path/to/Android/NDK>


=item B<-logtype xml|txt>

Output format f QtTestLib.

=item B<-runtype Time in minutes>

Maximum runtime for each test.

=item B<-no-build>

Script won't try to build the tests.

=back

=head1 DESCRIPTION

Script to run all qt tests in embedded device

=cut


