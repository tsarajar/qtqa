#!/usr/bin/env perl
#############################################################################
##
## Copyright (C) 2012 Digia Plc
## 
## For any questions to Digia, please use contact form at http://qt.digia.com
##
## $QT_BEGIN_LICENSE$
## Licensees holding valid Qt Commercial licenses may use this file in
## accordance with the Qt Commercial License Agreement provided with the 
## Software or, alternatively, in accordance with the terms contained in
## a written agreement between you and Digia.  
##
## If you have questions regarding the use of this file, please use
## contact form at http://qt.digia.com
## $QT_END_LICENSE$
##
#############################################################################

use strict;
use warnings;
use Cwd;
use feature ':5.10';
use IPC::System::Simple qw(system capture $EXITVAL EXIT_ANY); # requires libipc-system-simple-perl package
use Switch;
use Net::Ping;

$| = 1;

my $POWER_SWITCH_IP = $ENV{"POWER_SWITCH_IP"} || "qt-autotest-hp-powerswitch";
my $POWER_SWITCH_MODULE = $ENV{"POWER_SWITCH_MODULE"} || 0;
my $POWER_OUTLET_NUMBER = $ENV{"POWER_OUTLET_NUMBER"} || 0;
my $HW_REBOOT_SLEEP = $ENV{"HW_REBOOT_SLEEP"} || 5;
my $HW_POWEROFF_TIME = $ENV{"HW_POWEROFF_TIME"}|| 5;
my $PING_TIMEOUT = $ENV{"PING_TIMEOUT"} || 60;
my $PULSE_TESTS_DEVICE = $ENV{"PULSE_TESTS_DEVICE"}; #"qt-autotest-linux-beagle";
my $POWER_OUTLET_ID = "";
my $POWER_SWITCH_USER=$ENV{"POWER_SWITCH_USER"};
my $POWER_SWITCH_PWD=$ENV{"POWER_SWITCH_PWD"};

login();
sub login {
    print "Logging in to ${POWER_SWITCH_IP}\n";
    print "curl -c cookies.txt -silent -d \"userName=${POWER_SWITCH_USER}&password=${POWER_SWITCH_PWD}&language=1&dummy3=Sign+In&cleanup=&ErrorMsg=0\" http://${POWER_SWITCH_IP}/Forms/indexHTML_1\n";
    capture(EXIT_ANY, "curl -c cookies.txt -silent -d \"userName=${POWER_SWITCH_USER}&password=${POWER_SWITCH_PWD}&language=1&dummy3=Sign+In&cleanup=&ErrorMsg=0\" http://${POWER_SWITCH_IP}/Forms/indexHTML_1");
    if($EXITVAL != 0) {
        die "Login error: $EXITVAL";
    }
}

sub powerON {
    my ($login) = @_;
    $login = "-b cookies.txt";
    print "Powering on $POWER_OUTLET_ID\n";
    print "curl ${login} -silent -d \"${POWER_OUTLET_ID}=On\" http://${POWER_SWITCH_IP}/Form/Control.html\n";
    capture(EXIT_ANY, "curl ${login} -silent -d \"${POWER_OUTLET_ID}=On\" http://${POWER_SWITCH_IP}/Form/Control.html");
    if($EXITVAL != 0) {
        die "powerON error: $EXITVAL";
    }
}

sub powerOFF {
    my ($login) = @_;
    print "Powering off $POWER_OUTLET_ID\n";
    print capture(EXIT_ANY, "curl ${login} -silent -d \"${POWER_OUTLET_ID}=Off\" http://${POWER_SWITCH_IP}/Form/Control.html");
    if($EXITVAL != 0) {
        die "powerOFF error: $EXITVAL";
    }
}

sub reboot() {
    say "Rebooting the device...";
    powerOFF();
    if($HW_POWEROFF_TIME != 0) {
        sleep($HW_POWEROFF_TIME);
    }
    powerON();
}

sub rebootLogin() {
    say "Rebooting the device...";
    my $requireLogin = "-b cookies.txt";
    login();
    powerOFF($requireLogin);
    if($HW_POWEROFF_TIME != 0) {
        sleep($HW_POWEROFF_TIME);
    }
    powerON($requireLogin);
}

sub rebootAndWait() {
    reboot();
    say "Waiting $HW_REBOOT_SLEEP seconds";
    sleep($HW_REBOOT_SLEEP);
}

sub rebootAndPing() {
    reboot();
    say "Waiting for hw to respond ping (max. $PING_TIMEOUT seconds)";
    sleep(10);
    my $ping = Net::Ping->new();
    my $i = 0;
    do {
        $i += 5;
        print ".";
    } while ($i < $PING_TIMEOUT and (not $ping->ping($PULSE_TESTS_DEVICE, 5)));
    say "";

    die "\n$PULSE_TESTS_DEVICE did not respond to ping within $PING_TIMEOUT seconds"
        unless $ping->ping($PULSE_TESTS_DEVICE);

    $ping->close();
}


sub instructions() {
    say "Usage: powercycle.pl <option> <opt. params>\n";
    say "option:";
    say "--poweron";
    say "--poweroff";
    say "--reboot";
    say "--rebootandwait";
    say "--rebootandping\n";
    say "Optional parameters:";
    say "NOTE: parameters will override environment variables!";
    say "Pwr.sw module Pwr.module outlet\n";
    say "e.g. powercycle.pl --rebootandwait 1 3\n";
    say "Environment variables:";
    say "POWER_SWITCH_IP             [hostname or ip-address of the power switch]";
    say "POWER_SWITCH_MODULE         [Power switch outlet module number (1-6)]";
    say "POWER_OUTLET_NUMBER         [Selected module outlet number (1-4)]";
    say "HW_REBOOT_SLEEP             [Sleep time in seconds after reboot when using --rebootAndWait]";
    say "HW_POWEROFF_TIME            [Power off time in seconds when using --reboot or --rebootAndWait]";
    say "PING_TIMEOUT                [Timeout in seconds when using --rebootandping]";
    say "PULSE_TESTS_DEVICE          [Hostname or IP of the device you are power cycling when using --rebootandping]\n";
    say "Pulse Properties to set Environment variables:";
    say "tests.powerswitchaddress    [POWER_SWITCH_IP]";
    say "tests.powerswitchmodule     [POWER_SWITCH_MODULE]";
    say "tests.poweroutletnumber     [POWER_OUTLET_NUMBER]";
    say "tests.hwrebootsleep         [HW_REBOOT_SLEEP]";
    say "tests.powerofftime          [HW_POWEROFF_TIME]";
    say "tests.pingtimeout           [PING_TIMEOUT]";
    say "tests.device                [PULSE_TESTS_DEVICE]";
}

if ($ARGV[0] eq "--help") { instructions(); exit(); }

# Read optional parameters if exists
if ($ARGV[1]) {
    $POWER_SWITCH_MODULE = $ARGV[1];
}
if ($ARGV[2]) {
    $POWER_OUTLET_NUMBER = $ARGV[2];
}

# Verify module number and outlet number.
if ($POWER_SWITCH_MODULE < 1 || $POWER_SWITCH_MODULE > 6) {
    say "\nModule number Error: $POWER_SWITCH_MODULE, no such module\n"; instructions(); exit();
}
if ($POWER_OUTLET_NUMBER < 1 || $POWER_OUTLET_NUMBER > 5) {
    say "\nPower outlet number Error: $POWER_OUTLET_NUMBER, no such outlet\n"; instructions(); exit();
}

# Compose Power outled id from module number & outlet number
$POWER_OUTLET_ID = "core1St${POWER_SWITCH_MODULE}_${POWER_OUTLET_NUMBER}PowerOn";

switch ($ARGV[0]) {
    case "--poweron" { powerON(); }
    case "--poweroff" { powerOFF(); }
    case "--reboot" { reboot(); }
    case "--rebootlogin" { rebootLogin(); }
    case "--rebootandwait" { rebootAndWait(); }
    case "--rebootandping" { rebootAndPing(); }
    else { say "\nError: $ARGV[0], no such option\n"; instructions(); exit(); }
}

