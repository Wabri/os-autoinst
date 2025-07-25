#!/usr/bin/perl

use Test::Most;
use Mojo::Base -strict, -signatures;

use FindBin '$Bin';
use lib "$Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '5';
use Test::Output qw(stderr_like combined_from output_like combined_like);
use Test::Warnings qw(:report_warnings warning);
use Test::MockModule;
use Test::MockObject;
use File::Basename ();
use File::Path 'rmtree';

use autotest;
use bmwqemu;
use OpenQA::Test::RunArgs;

my $has_lua = eval { require Inline::Lua };

$bmwqemu::vars{CASEDIR} = File::Basename::dirname($0) . '/fake';

throws_ok { autotest::runalltests } qr/ERROR: no tests loaded/, 'runalltests needs tests loaded first';
like warning {
    throws_ok { autotest::loadtest 'does/not/match' } qr/loadtest.*does not match required pattern/,
    'loadtest catches incorrect test script paths'
  },
  qr/loadtest needs a script below.*is not/,
  'loadtest outputs on stderr';

sub loadtest ($test, $msg = "loadtest($test)") {
    my $filename = $test =~ /\.(p[my]|lua)$/ ? $test : $test . '.pm';
    $test =~ s/\.(p[my]|lua)//;
    stderr_like { autotest::loadtest "tests/$filename" } qr@scheduling $test#?[0-9]* tests/$test|$test already scheduled@, $msg;
}

my @sent;    # array of messages sent with the fake json_send
my @reset_consoles;
my @selected_consoles;
sub fake_send ($target, $msg) { push @sent, $msg }

sub fake_read ($fd, $cmd_token = undef) {
    my $lcmd = $sent[-1];
    my $cmd = $lcmd->{cmd};

    if ($cmd eq 'backend_reset_console') {
        push @reset_consoles, $lcmd;
        return {};
    }
    elsif ($cmd eq 'backend_select_console') {
        push @selected_consoles, $lcmd;
        return {};
    }

    return {};
}

# find the (first) 'tests_done' message from the @sent array and
# return the 'died' and 'completed' values
sub get_tests_done () {
    for my $msg (@sent) {
        if (ref $msg eq 'HASH' && $msg->{cmd} eq 'tests_done') {
            @sent = ();
            return ($msg->{died}, $msg->{completed});
        }
    }
}

my $mock_jsonrpc = Test::MockModule->new('myjsonrpc');
$mock_jsonrpc->redefine(send_json => \&fake_send);
$mock_jsonrpc->redefine(read_json => \&fake_read);
my $mock_bmwqemu = Test::MockModule->new('bmwqemu');
my $vm_stopped = 0;
$mock_bmwqemu->noop('save_json_file');
$mock_bmwqemu->redefine(stop_vm => sub { $vm_stopped = 1 });
my $mock_basetest = Test::MockModule->new('basetest');
$mock_basetest->noop('_result_add_screenshot');
# stop `run_all` from calling `Devel::Cover::report()` and quitting at the end
# note: We are not calling `run_all` from a sub process here so the extra coverage collection must *not* run.
my $mock_autotest = Test::MockModule->new('autotest', no_auto => 1);
$mock_autotest->noop('_terminate');

my $died;
my $completed;
like warning {
    stderr_like { autotest::run_all } qr/Sending tests_done/, 'tests_done sent';
}, qr/ERROR: no tests loaded/, 'run_all outputs status on stderr';

($died, $completed) = get_tests_done;
is($died, 1, 'run_all with no tests should catch runalltests dying');
is($completed, 0, 'run_all with no tests should not complete');

loadtest 'start';
loadtest 'next';
is(keys %autotest::tests, 2, 'two tests have been scheduled');
loadtest 'start', 'rescheduling same step later';
is(keys %autotest::tests, 3, 'three steps have been scheduled (one twice)') || always_explain %autotest::tests;
is($autotest::tests{'tests-start1'}->{name}, 'start#1', 'handle duplicate tests');
is($autotest::tests{'tests-start1'}->{fullname}, 'tests-start#1', 'duplicate test has correct fullname');
is($autotest::tests{'tests-start1'}->{$_}, $autotest::tests{'tests-start'}->{$_}, "duplicate tests point to the same $_")
  for qw(script category class);

like warning {
    stderr_like { autotest::run_all } qr/Sending tests_done/, 'tests_done sent';
}, qr/isotovideo.*not initialized/, 'autotest methods need a valid isotovideo socket';

@sent = ();
$autotest::isotovideo = 1;
stderr_like { autotest::run_all } qr/finished/, 'run_all outputs status on stderr';
($died, $completed) = get_tests_done;
is($died, 0, 'start+next+start should not die');
is($completed, 1, 'start+next+start should complete');

# Test loading snapshots with always_rollback flag. Have to put it here, before loading
# runargs test module, as it fails.
my ($reverts_done, $snapshots_made) = (0, 0);
# uncoverable statement count:2
$mock_autotest->redefine(load_snapshot => sub { $reverts_done++ });
$mock_autotest->redefine(make_snapshot => sub { $snapshots_made++ });
$mock_autotest->redefine(query_isotovideo => 0);
$mock_basetest->redefine(test_flags => {milestone => 1});
$mock_basetest->noop('record_resultfile');
sub snapshot_subtest ($name, $sub) { subtest $name, $sub; $reverts_done = $snapshots_made = 0; @sent = () }

subtest 'test always_rollback flag' => sub {
    snapshot_subtest 'no rollback is triggered when flag is not explicitly set to true' => sub {
        stderr_like { autotest::run_all } qr/finished/, 'run_all outputs status on stderr';
        ($died, $completed) = get_tests_done;
        is $died, 0, 'start+next+start should not die when always_rollback flag is set';
        is $completed, 1, 'start+next+start should complete when always_rollback flag is set';
        is $reverts_done, 0, 'no snapshots loaded when flag is not explicitly set to true';
        is $snapshots_made, 0, 'no snapshots made if snapshots are not supported';
    };
    snapshot_subtest 'no rollback is triggered if snapshots are not supported' => sub {
        $mock_basetest->redefine(test_flags => {always_rollback => 1, milestone => 1});
        $mock_autotest->redefine(query_isotovideo => 0);
        $mock_autotest->redefine(load_snapshot => sub { $reverts_done++; });
        stderr_like { autotest::run_all } qr/finished/, 'run_all outputs status on stderr';
        ($died, $completed) = get_tests_done;
        is $died, 0, 'start+next+start should not die when always_rollback flag is set';
        is $completed, 1, 'start+next+start should complete when always_rollback flag is set';
        is $reverts_done, 0, 'no snapshots loaded if snapshots are not supported';
        is $snapshots_made, 0, 'no snapshots made if snapshots are not supported';
    };
    snapshot_subtest 'snapshot loading triggered even when tests successful' => sub {
        $mock_basetest->redefine(test_flags => {always_rollback => 1});
        $mock_autotest->redefine(query_isotovideo => 1);
        stderr_like { autotest::run_all } qr/finished/, 'run_all outputs status on stderr';
        ($died, $completed) = get_tests_done;
        is $died, 0, 'start+next+start should not die when always_rollback flag is set';
        is $completed, 1, 'start+next+start should complete when always_rollback flag is set';
        is $reverts_done, 0, 'no snapshots loaded if not test with milestone flag';
        is $snapshots_made, 0, 'no snapshots made if snapshots are not supported';
    };
    snapshot_subtest 'snapshot loading with milestone flag' => sub {
        $mock_basetest->redefine(test_flags => {always_rollback => 1, milestone => 1});
        stderr_like { autotest::run_all } qr/finished/, 'run_all outputs status on stderr';
        ($died, $completed) = get_tests_done;
        is $died, 0, 'start+next+start should not die when always_rollback flag is set';
        is $completed, 1, 'start+next+start should complete when always_rollback flag is set';
        is $reverts_done, 1, 'snapshots are loaded even when tests succeed';
        is $snapshots_made, 2, 'milestone snapshots are made for all except the last';
    };
    snapshot_subtest 'snapshot loading with milestone flag and fatal test' => sub {
        $mock_basetest->redefine(test_flags => {milestone => 1, fatal => 1});
        stderr_like { autotest::run_all } qr/finished/, 'run_all outputs status on stderr';
        ($died, $completed) = get_tests_done;
        is $died, 0, 'start+next+start should not die as fatal milestones';
        is $completed, 1, 'start+next+start should complete as fatal milestones';
        is $reverts_done, 0, 'no rollbacks done';
        is $snapshots_made, 0, 'no snapshots made as no test needed them';
    };
    snapshot_subtest 'stopping overall test execution early due to fatal test failure' => sub {
        $mock_basetest->redefine(runtest => sub { die "test died\n" });
        $vm_stopped = 0;
        $bmwqemu::vars{DUMP_MEMORY_ON_FAIL} = 1;
        stderr_like { autotest::run_all } qr/.*stopping overall test execution after a fatal test failure.*/, 'reason logged';
        ($died, $completed) = get_tests_done;
        is $died, 0, 'tests still not considered died if only a test module failed';
        is $completed, 0, 'tests not considered completed';
        is $reverts_done, 0, 'no rollbacks done';
        is $snapshots_made, 0, 'no snapshots made';
        ok $vm_stopped, 'VM has been stopped';
    };
    snapshot_subtest 'stopping overall test execution early due to snapshotting not available' => sub {
        $mock_basetest->redefine(test_flags => {milestone => 1});
        $mock_autotest->redefine(query_isotovideo => 0);
        stderr_like { autotest::run_all } qr/.*stopping overall test execution because snapshotting is disabled.*/, 'reason logged';
    };
    snapshot_subtest 'stopping overall test execution early due to TESTDEBUG' => sub {
        $bmwqemu::vars{TESTDEBUG} = 1;
        stderr_like { autotest::run_all } qr/.*stopping overall test execution because TESTDEBUG has been set.*/, 'reason logged (TESTDEBUG)';
        delete $bmwqemu::vars{TESTDEBUG};
    };
    $mock_basetest->unmock($_) for qw(runtest test_flags);
    $mock_autotest->unmock($_) for qw(load_snapshot make_snapshot query_isotovideo);
};

my $targs = OpenQA::Test::RunArgs->new();
stderr_like {
    autotest::loadtest("tests/run_args.pm", name => 'alt_name', run_args => $targs)
}
qr@scheduling alt_name tests/run_args.pm@;
stderr_like { autotest::run_all } qr/finished alt_name tests/, 'dynamic scheduled alt_name shows up';
($died, $completed) = get_tests_done;
is($died, 0, 'run_args test should not die');
is($completed, 1, 'run_args test should complete');

stderr_like { autotest::loadtest("tests/run_args.pm", name => 'alt_name') } qr@scheduling alt_name tests/run_args.pm@;
stderr_like { autotest::run_all } qr/Snapshots are not supported/, 'run_all outputs status on stderr';
($died, $completed) = get_tests_done;
is($died, 0, 'run_args test should not die if there is no run_args');
is($completed, 0, 'run_args test should not complete if there is no run_args');

throws_ok { autotest::loadtest("tests/run_args.pm", name => 'alt_name', run_args => {foo => 'bar'}) } qr/The run_args must be a sub-class of OpenQA::Test::RunArgs/, 'error message mentions RunArgs';

# now let's make the tests fail...but so far none is fatal. We also
# have to mock query_isotovideo so we think snapshots are supported.
# we cause the failure by mocking runtest rather than using a test
# which dies, as runtest does a whole bunch of stuff when the test
# dies that we may not want to run into here
$mock_basetest->redefine(runtest => sub { die 'oh noes!' });
my $enable_snapshots = 1;
$mock_autotest->redefine(query_isotovideo => sub ($command, $arguments) {
        $command eq 'backend_can_handle' && $arguments->{function} eq 'snapshots' ? $enable_snapshots : 1;
});

my $record_resultfile_called;
$mock_basetest->redefine(record_resultfile => sub { ++$record_resultfile_called });
stderr_like { autotest::run_all } qr/oh noes/, 'run_all outputs status on stderr';
($died, $completed) = get_tests_done;
is($died, 0, 'non-fatal test failure should not die');
is($completed, 1, 'non-fatal test failure should complete');
is $record_resultfile_called, 4, 'record_resultfile was called';

# now let's add an ignore_failure test
loadtest 'ignore_failure';
stderr_like { autotest::run_all } qr/oh noes/, 'run_all outputs status on stderr';
($died, $completed) = get_tests_done;
is($died, 0, 'unimportant test failure should not die');
is($completed, 1, 'unimportant test failure should complete');

# unmock runtest, to fail in search_for_expected_serial_failures
$mock_basetest->unmock('runtest');
# mock reading of the serial output
$mock_basetest->redefine(search_for_expected_serial_failures => sub ($self) {
        $self->{fatal_failure} = 1;
        die "Got serial hard failure";
});

$bmwqemu::vars{MAKETESTSNAPSHOTS} = 1;
stderr_like { autotest::run_all } qr/Snapshots are supported/, 'run_all outputs status on stderr';
($died, $completed) = get_tests_done;
is($died, 0, 'fatal serial failure test should not die');
is($completed, 0, 'fatal serial failure test should not complete');
$bmwqemu::vars{MAKETESTSNAPSHOTS} = 0;
# make the serial failure non-fatal
$mock_basetest->unmock('search_for_expected_serial_failures');
$mock_basetest->redefine(search_for_expected_serial_failures => sub ($self) {
        $self->{fatal_failure} = 0;
        die "Got serial hard failure";
});

$autotest::current_test = Test::MockObject->new->set_true('record_resultfile');
stderr_like { autotest::run_all } qr/Snapshots are supported/, 'run_all outputs status on stderr';
($died, $completed) = get_tests_done;
is($died, 0, 'non-fatal serial failure test should not die');
is($completed, 1, 'non-fatal serial failure test should complete');

# disable snapshots and clean last milestone from previous testrun (with had snapshots enabled)
$enable_snapshots = 0;
$autotest::last_milestone = undef;

my $output = combined_from(sub { autotest::run_all });
like($output, qr/Snapshots are not supported/, 'snapshots actually disabled');
unlike($output, qr/Loading a VM snapshot/, 'no attempt to load VM snapshot');
($died, $completed) = get_tests_done;
is($died, 0, 'non-fatal serial failure test should not die');
is($completed, 0, 'non-fatal serial failure test should not complete by default without snapshot support');

$mock_basetest->redefine(test_flags => {fatal => 0});
$output = combined_from(sub { autotest::run_all });
like($output, qr/Snapshots are not supported/, 'snapshots actually disabled');
unlike($output, qr/Loading a VM snapshot/, 'no attempt to load VM snapshot');
($died, $completed) = get_tests_done;
is($died, 0, 'non-fatal serial failure test should not die');
is($completed, 1, 'non-fatal serial failure test should complete with {fatal => 0} and not snapshot support');

# Revert mock for runtest and remove mock for search_for_expected_serial_failures
$mock_basetest->unmock('search_for_expected_serial_failures');
$mock_basetest->unmock('test_flags');
$mock_basetest->redefine(runtest => sub { die "oh noes!\n"; });

# now let's add a fatal test
loadtest 'fatal';
stderr_like { autotest::run_all } qr/oh noes/, 'run_all outputs status on stderr';
($died, $completed) = get_tests_done;
is($died, 0, 'fatal test failure should not die');
is($completed, 0, 'fatal test failure should not complete');

loadtest 'fatal', 'rescheduling same step later' for 1 .. 10;
my @opts = qw(script fullname category class);
is(@{$autotest::tests{'tests-fatal'}}{@opts}, @{$autotest::tests{'tests-fatal' . $_}}{@opts}, "tests-fatal$_ share same options with tests-fatal")
  && is(@{$autotest::tests{'tests-fatal' . $_}}{name}, 'fatal#' . $_)
  for 1 .. 10;

subtest 'test scheduling test modules at test runtime' => sub {
    $autotest::tests_running = 0;
    @autotest::testorder = ();
    %autotest::tests = ();

    my %json_data;
    my $json_filename = bmwqemu::result_dir . '/test_order.json';
    my @testorder = (
        {name => 'scheduler', category => 'tests', flags => {}, script => 'tests/scheduler.pm'},
        {name => 'next', category => 'tests', flags => {}, script => 'tests/next.pm'}
    );

    $mock_basetest->unmock('runtest');
    $mock_bmwqemu->redefine(save_json_file => sub ($data, $filename) { $json_data{$filename} = $data });

    loadtest 'scheduler';
    ok !defined $json_data{$json_filename}, 'loadtest should not create test_order.json before tests started';

    stderr_like { autotest::run_all } qr#scheduling next tests/next\.pm#, 'new test module gets scheduled at runtime';
    is scalar @autotest::testorder, 2, 'loadtest adds new modules at runtime';
    is_deeply $json_data{$json_filename}, \@testorder, 'loadtest updates test_order.json at test runtime';

    $mock_bmwqemu->noop('save_json_file');
};

my $sharedir = '/home/tux/.local/lib/openqa/share';
is(autotest::parse_test_path("$sharedir/tests/sle/tests/x11/firefox.pm"), 'x11');
is(autotest::parse_test_path("$sharedir/tests/sle/tests/x11/toolkits/motif.pm"), 'x11/toolkits');
is(autotest::parse_test_path("$sharedir/factory/other/sysrq.pm"), 'other');

subtest 'load test successfully when CASEDIR is a relative path' => sub {
    symlink($bmwqemu::vars{CASEDIR}, 'foo');
    $bmwqemu::vars{CASEDIR} = 'foo';
    like warning { loadtest 'start' }, qr{Subroutine run redefined}, 'We get a warning for loading a test a second time';
};

my $has_python = eval { require Inline::Python };

subtest python => sub {
    plan skip_all => 'Inline::Python is not available' unless $has_python;

    combined_like {
        lives_ok { autotest::loadtest('tests/pythontest.py') } 'can load test module'
    } qr{Using python version.*scheduling pythontest tests/pythontest}s, 'python pythontest module referenced';

    %autotest::tests = ();
    loadtest 'pythontest.py';
    loadtest 'morepython.py';
    my $p1 = $autotest::tests{'tests-pythontest'};
    my $p2 = $autotest::tests{'tests-morepython'};
    stderr_like { $p1->runtest } qr{This is pythontest.py}, 'Expected output from pythontest.py';
    stderr_like { $p2->runtest } qr{This is morepython.py}, 'Expected output from morepython.py';
    is $bmwqemu::vars{HELP}, 'I am a python script trapped in a perl script!', 'set_var() works';

    stderr_like {
        throws_ok { autotest::loadtest 'tests/faulty.py' } qr/py_eval raised an exception/, 'dies on Python exception';
    } qr/Traceback.*No module named.*thismoduleshouldnotexist.*/s, 'Python traceback logged';
};

subtest 'python run_args' => sub {
    plan skip_all => 'Inline::Python is not available' unless $has_python;

    %autotest::tests = ();
    my $targs = OpenQA::Test::RunArgs->new();
    $targs->{data} = 23;

    throws_ok { autotest::loadtest('tests/pythontest_with_runargs.py', run_args => $targs) } qr/run_args is not supported in Python test modules/, 'error message mentions run_args and python';
};

subtest 'python with bad run method' => sub {
    plan skip_all => 'Inline::Python is not available' unless $has_python;

    %autotest::tests = ();
    my $targs = OpenQA::Test::RunArgs->new();
    $targs->{data} = 23;

    my @msg;
    $mock_bmwqemu->mock(diag => sub ($message) { push @msg, $message });
    autotest::loadtest('tests/pythontest_with_bad_run_fn.py');
    is $msg[0], 'scheduling pythontest_with_bad_run_fn tests/pythontest_with_bad_run_fn.py', 'debug message from autotest';
    $mock_bmwqemu->unmock('diag');

    loadtest 'pythontest_with_bad_run_fn.py';
    my $p1 = $autotest::tests{'tests-pythontest_with_bad_run_fn'};

    stderr_like {
        throws_ok { $p1->runtest } qr{test pythontest_with_bad_run_fn died}, "expected failure on python side";
    } qr{TypeError: run\(\) takes 0 positional arguments but 1 was given}, 'Expected output from pythontest_with_bad_runargs.py';
    is $bmwqemu::vars{PY_SUPPORT_FN_NOT_CALLED}, undef, 'set_var() was never called';
};

subtest 'pausing on failure' => sub {
    my $autotest_mock = Test::MockModule->new('autotest');
    my %isotovideo_rsp = (ignore_failure => 1);
    my @isotovideo_calls;
    $autotest_mock->redefine(query_isotovideo => sub (@args) { push @isotovideo_calls, \@args; \%isotovideo_rsp });
    my $rsp = autotest::pause_on_failure('some reason', 'relevant command');
    is_deeply $rsp, \%isotovideo_rsp, 'response from isotovideo returned';
    is $isotovideo_calls[0]->[0], 'pause_test_execution', 'isotovideo called to pause test execution';
    autotest::pause_on_failure('some reason');
    is scalar @isotovideo_calls, 2, 'isotovideo called again just after failing command because failure was ignored';
    undef $isotovideo_rsp{ignore_failure};
    autotest::pause_on_failure('another reason', 'relevant command');
    is scalar @isotovideo_calls, 3, 'isotovideo called again after a command failed';
    autotest::pause_on_failure('another reason');
    is scalar @isotovideo_calls, 3, 'isotovideo not called after tests died because previous command failure was not ignored';
};

subtest rollback_activated_consoles => sub {
    $mock_autotest->unmock('query_isotovideo');

    $autotest::activated_consoles = ['activated_console'];
    $autotest::last_milestone_console = 'last_milestone_console';
    autotest::rollback_activated_consoles();
    is(scalar(@$autotest::activated_consoles), 0, 'activated consoles cleared');
    is_deeply(\@reset_consoles, [{cmd => 'backend_reset_console', testapi_console => 'activated_console'}], 'activated consoles reset');
    is_deeply(\@selected_consoles, [{cmd => 'backend_select_console', testapi_console => 'last_milestone_console'}], 'last milestone console selected');
};

subtest find_script => sub {
    my $override_path = 0;
    $bmwqemu::vars{WHEELS_DIR} = '';    # overwrite WHEELS_DIR and set it empty
    $bmwqemu::vars{ASSETDIR} = Cwd::getcwd . '/t/data/assets';
    $bmwqemu::vars{CASEDIR} = File::Basename::dirname($0) . '/fake';
    stderr_like {
        $override_path = autotest::find_script('start.pm');
    } qr/Found override test module for/, 'Using Override Path';
    is $override_path, '../data/assets/other/start.pm', 'find script successful';
};

subtest make_snapshot => sub {
    my $rsp = 0;
    my $autotest_mock = Test::MockModule->new('autotest');
    my %isotovideo_rsp = (snapshot_done => 1);
    my @isotovideo_calls;
    $autotest_mock->redefine(query_isotovideo => sub (@args) { push @isotovideo_calls, \@args; \%isotovideo_rsp });
    stderr_like {
        $rsp = autotest::make_snapshot('test-snapshot');
    } qr/Creating a VM snapshot test-snapshot/, 'Snapshot Successful';
    is_deeply $rsp, \%isotovideo_rsp, 'response from isotovideo returned';
    $autotest_mock->unmock('query_isotovideo');
};

subtest loadtestdir => sub {
    $bmwqemu::vars{CASEDIR} = 't/data/tests';
    stderr_like {
        autotest::loadtestdir('tests');
    } qr/debug.*scheduling/, 'loadtestdir is scheduling successfully (perl)';
    ok exists $autotest::tests{'tests-boot'}, 'boot.pm loaded';
    if ($has_lua) {
        my $w = warning { stderr_like {
                autotest::loadtestdir('luatests');
        } qr/debug.*scheduling/, 'loadtestdir is scheduling successfully (lua)'; };
        like $w, qr{'testfunc37' is not exported by 'testlib'}, 'Warn about requesting not-exported method';
        ok exists $autotest::tests{'luatests-unittest_lua'}, 'unittest_lua.lua loaded';
    }
    if ($has_python) {
        stderr_like {
            autotest::loadtestdir('pythontests');
        } qr/debug.*scheduling/, 'loadtestdir is scheduling successfully (python)';
        ok exists $autotest::tests{'pythontests-pre_boot'}, 'pre_boot.py loaded';
    }
};

subtest croak => sub {
    my $autotest_mock = Test::MockModule->new('autotest');
    my %isotovideo_rsp = (ignore_failure => 0);
    my @isotovideo_calls;
    $autotest_mock->redefine(query_isotovideo => sub (@args) { push @isotovideo_calls, \@args; \%isotovideo_rsp });
    throws_ok { autotest::croak('ls', 'test error from croak') } qr/test error from croak/, 'Croak test error caught';
    $autotest_mock->unmock('query_isotovideo');
};

subtest 'test skipping tests' => sub {
    $bmwqemu::vars{SKIPTO} = 'pythontest.py';
    stderr_like { autotest::runalltests } qr/skipping/, 'Skipping Test Run';
};

subtest 'start_process' => sub {
    my $fh;
    open $fh, '<', \"fake-file";
    $autotest::isotovideo = $fh;
    # Test the start_process subroutine
    my ($process, $child) = autotest::start_process();

    isa_ok $process, 'HASH', 'start_process returns a HASH reference';
    isa_ok $child, 'GLOB', '$child is a GLOB reference';

    ok $child->autoflush, 'autoflush was called on child handle';
    ok $fh->autoflush, 'autoflush was called on isotovideo handle';

    open $fh, '<', \"fake-file";
    $autotest::isotovideo = $fh;
    stderr_like { $process->{code}->(); } qr/Snapshots are not supported/, 'run_all outputs status on stderr';
};

subtest 'lua_use' => sub {
    my $lua_vars = {};
    $mock_autotest->mock('lua_set' => sub ($k, $v) { $lua_vars->{$k} = $v; });
    autotest::_lua_use('testapi');
    is $lua_vars->{realname}, 'Bernhard M. Wiedemann', 'Check importing strings';
    is ref($lua_vars->{assert_script_run}), 'CODE', 'Check importing functions';

    autotest::_lua_use('testlib');
    is $lua_vars->{testfunc1}(), 42, 'Exported function is imported';
    is $lua_vars->{testfunc2}, undef;
    autotest::_lua_use('testlib', ['testfunc2']);
    is $lua_vars->{testfunc2}(), 43, 'Explicit imports of non-exported functions';
    is_deeply $lua_vars->{testarray}, [1, 2, 3], 'Import Array';
    is_deeply $lua_vars->{testhash}, {foo => 'bar'}, 'Import Hash';
};

subtest 'lua_runtest' => sub {
    plan skip_all => 'Inline::Lua is not available' unless $has_lua;

    my $luatest = $autotest::tests{'luatests-unittest_lua'};
    my $out = combined_from { $luatest->runtest() };
    like $out, qr{testfunc1\ntestfunc2\ntestfunc3}, 'function calls work';
    like $out, qr{testarray:\t1,2,3}, 'arrays work';
    like $out, qr{foo = bar}, 'hashes work';
};


done_testing();

END {
    unlink "vars.json", "base_state.json", "foo";
    rmtree "testresults";
}
