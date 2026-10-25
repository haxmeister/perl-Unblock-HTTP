use v5.36;
use strict;
use warnings;
use Config ();
use File::Path qw(make_path);
use File::Spec;
use FindBin;
use Getopt::Long qw(GetOptions);
use JSON::PP ();
use POSIX qw(strftime uname);

# A dedicated-Linux-host driver for the isolated real-QUIC profiler.
# All measurements, logs and a checkpointed manifest remain on that host.
my ($samples, $warmup, $rounds, $rotate, $swap, $dry_run, $only, $pair) =
    (2048, 128, 7, 0, 0, 0);
GetOptions(
    'samples=i' => \$samples, 'warmup=i' => \$warmup,
    'rounds=i' => \$rounds, 'rotate=i' => \$rotate,
    'swap-url-order!' => \$swap, 'dry-run!' => \$dry_run,
    'only=s' => \$only, 'pair=s' => \$pair,
) or die "invalid sweep options\n";
my ($output_dir) = @ARGV;
die "usage: perl bench/h3-profile-sweep.pl [--samples=N --warmup=N --rounds=N --rotate=0..9 --swap-url-order --only=CASE_ID --pair=PAIR_ID --dry-run] OUTPUT_DIR\n"
    unless @ARGV == 1 && defined($output_dir) && length($output_dir);
die "samples must be 1..20000\n"
    unless $samples >= 1 && $samples <= 20000;
die "warmup must be 1..2000\n"
    unless $warmup >= 1 && $warmup <= 2000;
die "rounds must be 1..15\n"
    unless $rounds >= 1 && $rounds <= 15;
die "rotate must be 0..9\n" unless $rotate >= 0 && $rotate <= 9;

sub write_json ($path, $value) {
    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or die "cannot open $tmp: $!\n";
    print {$fh} JSON::PP->new->canonical->pretty->encode($value)
        or die "cannot write $tmp: $!\n";
    close $fh or die "cannot close $tmp: $!\n";
    rename $tmp, $path or die "cannot rename $tmp to $path: $!\n";
}

sub read_json ($path) {
    open my $fh, '<', $path or die "cannot read $path: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    return JSON::PP->new->decode($data);
}

sub first_file_line ($path, $pattern) {
    open my $fh, '<', $path or return undef;
    while (my $line = <$fh>) {
        if ($line =~ $pattern) {
            close $fh;
            return $1;
        }
    }
    close $fh;
    return undef;
}

sub command_output (@command) {
    open my $fh, '-|', @command or return undef;
    my $line = <$fh>;
    close $fh;
    return defined($line) ? $line =~ s/\s+\z//r : undef;
}

# Keep pairs of URL patterns adjacent. Rotate the ten payload/concurrency
# pairs, not individual requests. Reverse URL order in subsequent sweeps.
my @pairs;
for my $body ('1024', '4096,16384', '65536') {
    for my $inflight ($body eq '65536' ? (1, 8) : (1, 8, 16, 32)) {
        push @pairs, { body => $body, inflight => $inflight };
    }
}
@pairs = (@pairs[$rotate .. $#pairs], @pairs[0 .. $rotate - 1])
    if $rotate;
my @cases;
for my $pair (@pairs) {
    for my $url_mode ($swap ? qw(unique cycled) : qw(cycled unique)) {
        my $body_slug = $pair->{body} =~ s/,/-/gr;
        my $id = sprintf 'c%02d-b%s-%s', $pair->{inflight},
            $body_slug, $url_mode;
        push @cases, {
            id => $id, inflight => $pair->{inflight},
            response_bytes => $pair->{body}, url_mode => $url_mode,
            json => "$id.json", log => "$id.log",
        };
    }
}
die "--only and --pair are mutually exclusive\n"
    if defined($only) && defined($pair);
if (defined $only) {
    @cases = grep { $_->{id} eq $only } @cases;
    die "unknown scenario $only\n" unless @cases;
}
if (defined $pair) {
    @cases = grep { $_->{id} =~ /\A\Q$pair\E-(?:cycled|unique)\z/ } @cases;
    die "unknown workload pair $pair\n" unless @cases == 2;
}
if ($dry_run) {
    print "# dry-run; no QUIC, directories, or measurements created\n";
    print "# samples=$samples warmup=$warmup rounds=$rounds rotate=$rotate swap_url_order=$swap\n";
    print join(' ', $_->{id}, $_->{inflight}, $_->{response_bytes}, $_->{url_mode}), "\n"
        for @cases;
    exit 0;
}

require Net::QUIC;
# Comparisons are matched within each run and record the exact QUIC
# version. Requiring one historic version unnecessarily rejects newer
# published, API-compatible Net::QUIC releases.
die "controlled real-QUIC sweep requires Net::QUIC >= 0.05\n"
    unless $Net::QUIC::VERSION >= 0.05;
for my $key (qw(UNBLOCK_H3_PROFILE_CHECKPOINT_EVERY
                UNBLOCK_H3_PROFILE_REGISTRY UNBLOCK_H3_PROFILE_ASSERT_BOUNDED
                UNBLOCK_H3_PROFILE_WIRE UNBLOCK_H3_HEAP_DIR)) {
    die "disable $key for timing sweeps\n" if $ENV{$key};
}
die "refusing to overwrite existing output directory $output_dir\n"
    if -e $output_dir;
make_path($output_dir);
$output_dir = File::Spec->rel2abs($output_dir);
my $profile_script = File::Spec->catfile($FindBin::Bin, 'h3-workload-profile.pl');
die "missing profiler $profile_script\n" unless -f $profile_script;
my $repo_root = File::Spec->catdir($FindBin::Bin, '..');
my @uname = uname();
my $host = {
    perl => "$]", perl_executable => $^X,
    archname => $Config::Config{archname},
    uname => \@uname,
    cpu_model => first_file_line('/proc/cpuinfo', qr/^model name\s*:\s*(.+?)\s*$/),
    cpu_governor => first_file_line(
        '/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor', qr/^(\S+)/),
    upper_commit => command_output('git', '-C', $repo_root, 'rev-parse', 'HEAD'),
    net_quic_version => $Net::QUIC::VERSION,
};
my $manifest = {
    schema_version => 1,
    started_at_utc => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime()),
    host => $host,
    workload => {
        samples => $samples, warmup => $warmup, rounds => $rounds,
        rotate => $rotate,
        swap_url_order => $swap ? JSON::PP::true : JSON::PP::false,
        note => 'Loopback real QUIC; timing experiments, not performance gates',
    },
    complete => JSON::PP::false,
    cases => \@cases,
};
my $manifest_path = File::Spec->catfile($output_dir, 'sweep.json');
write_json($manifest_path, $manifest);
for my $case (@cases) {
    my $log_path = File::Spec->catfile($output_dir, $case->{log});
    my $json_path = File::Spec->catfile($output_dir, $case->{json});
    print "# running $case->{id}\n";
    my $pid = fork();
    die "sweep fork failed: $!\n" unless defined($pid);
    if (!$pid) {
        open STDOUT, '>', $log_path or die "log open: $!\n";
        open STDERR, '>&', \*STDOUT or die "log stderr redirect: $!\n";
        $ENV{UNBLOCK_H3_PROFILE_URL_MODE} = $case->{url_mode};
        $ENV{UNBLOCK_H3_PROFILE_JSON_FILE} = $json_path;
        exec $^X, "-I$repo_root/blib/lib", "-I$repo_root/blib/arch",
            $profile_script, $samples, $warmup, $rounds,
            $case->{inflight}, $case->{response_bytes};
        die "exec profiler failed: $!\n";
    }
    waitpid($pid, 0) == $pid or die "waitpid failed: $!\n";
    my $status = $?;
    if ($status) {
        $case->{failed_status} = $status;
        write_json($manifest_path, $manifest);
        die "profiler $case->{id} failed ($status); see $log_path\n";
    }
    my $report = eval { read_json($json_path) };
    if (!$report) {
        $case->{failed_error} = "invalid/missing JSON report: $@";
        write_json($manifest_path, $manifest);
        die $case->{failed_error};
    }
    my $valid_report = eval {
        $report->{schema_version} == 1
            && $report->{workload}{url_mode} eq $case->{url_mode}
            && $report->{workload}{inflight} == $case->{inflight}
            && join(',', @{$report->{workload}{response_bytes}})
                eq $case->{response_bytes}
            && $report->{workload}{samples} == $samples
            && $report->{workload}{rounds} == $rounds
            && @{$report->{summary}{paired}} == $rounds
            && @{$report->{trials}} == 2 * $rounds;
    };
    if (!$valid_report) {
        $case->{failed_error} = 'profile report contents did not match scenario';
        write_json($manifest_path, $manifest);
        die "$case->{failed_error}: $case->{id}\n";
    }
    $case->{median_paired_wall_ratio} =
        $report->{summary}{median_paired_wall_ratio};
    $case->{done} = JSON::PP::true;
    write_json($manifest_path, $manifest);
}
$manifest->{complete} = JSON::PP::true;
$manifest->{finished_at_utc} = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
write_json($manifest_path, $manifest);
print "# complete: $manifest_path (" . scalar(@cases)
    . " scenarios, $rounds paired rounds each)\n";
