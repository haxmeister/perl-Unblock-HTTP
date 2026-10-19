use v5.36;
use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use lib "$FindBin::Bin/lib";
use H3Profile::Summary qw(summarize_trials);
use File::Spec;
use Getopt::Long qw(GetOptions);
use JSON::PP ();

my $json_output;
GetOptions('json=s' => \$json_output) or die "invalid option\n";
die "usage: perl bench/h3-compare-sweeps.pl [--json=FILE] FIRST_DIR SECOND_DIR\n"
    unless @ARGV == 2;

sub load_json ($path) {
    open my $fh, '<', $path or die "cannot open $path: $!\n";
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $value = eval { JSON::PP->new->decode($raw) };
    die "bad JSON $path: $@\n" if $@;
    die "expected JSON object in $path\n" unless ref($value) eq 'HASH';
    return $value;
}
sub same ($a, $b) {
    return 1 if !defined($a) && !defined($b);
    return defined($a) && defined($b) && !ref($a) && !ref($b)
        && "$a" eq "$b";
}
sub median (@numbers) {
    die "missing observations\n" unless @numbers;
    @numbers = sort { $a <=> $b } @numbers;
    my $middle = int(@numbers / 2);
    return @numbers % 2 ? $numbers[$middle]
        : ($numbers[$middle - 1] + $numbers[$middle]) / 2;
}
sub display_delta ($value) {
    return defined($value) ? sprintf('%+.0f', $value) : 'NA';
}
sub load_sweep ($directory) {
    my $manifest = load_json(File::Spec->catfile($directory, 'sweep.json'));
    die "incomplete sweep $directory\n"
        unless $manifest->{schema_version} == 1 && $manifest->{complete};
    die "missing host/workload/cases $directory\n"
        unless ref($manifest->{host}) eq 'HASH'
            && ref($manifest->{workload}) eq 'HASH'
            && ref($manifest->{cases}) eq 'ARRAY' && @{$manifest->{cases}};
    my %cases;
    for my $case (@{$manifest->{cases}}) {
        die "invalid sweep case in $directory\n"
            unless ref($case) eq 'HASH' && $case->{done}
                && defined($case->{id})
                && $case->{id}
                    =~ /\Ac(?:01|08|16|32)-b(?:1024|4096-16384|65536)-(?:cycled|unique)\z/
                && defined($case->{json})
                && $case->{json} eq "$case->{id}.json";
        die "duplicate sweep case $case->{id}\n"
            if exists $cases{$case->{id}};
        my $report = load_json(File::Spec->catfile($directory, $case->{json}));
        my $work = $report->{workload};
        die "mismatched profile workload for $case->{id}\n"
            unless $report->{schema_version} == 1
                && ref($work) eq 'HASH'
                && ref($report->{trials}) eq 'ARRAY'
                && ref($report->{summary}) eq 'HASH'
                && same($work->{samples}, $manifest->{workload}{samples})
                && same($work->{warmup}, $manifest->{workload}{warmup})
                && same($work->{rounds}, $manifest->{workload}{rounds})
                && same($work->{inflight}, $case->{inflight})
                && same($work->{url_mode}, $case->{url_mode})
                && ref($work->{response_bytes}) eq 'ARRAY'
                && join(',', @{$work->{response_bytes}})
                    eq $case->{response_bytes};
        my $summary = summarize_trials(
            $report->{trials}, $manifest->{workload}{rounds});
        die "corrupt saved profile summary for $case->{id}\n"
            unless defined($report->{summary}{median_paired_wall_ratio})
                && !ref($report->{summary}{median_paired_wall_ratio})
                && $report->{summary}{median_paired_wall_ratio}
                    =~ /\A[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/
                && abs($summary->{median_paired_wall_ratio}
                    - $report->{summary}{median_paired_wall_ratio}) < 0.000001;
        # Never pool direct and unified memory observations from
        # independently forked trial processes. No allocation counts.
        my %memory_deltas;
        for my $trial (@{$report->{trials}}) {
            for my $metric (qw(rss pss private)) {
                my ($start, $end) =
                    @{$trial}{$metric . '_start', $metric . '_end'};
                next unless defined($start) && defined($end)
                    && !ref($start) && !ref($end)
                    && $start =~ /\A[0-9]+(?:\.[0-9]+)?\z/
                    && $end =~ /\A[0-9]+(?:\.[0-9]+)?\z/;
                push @{$memory_deltas{$metric}{$trial->{mode}}},
                    $end - $start;
            }
        }
        my %memory_summary;
        for my $metric (qw(rss pss private)) {
            for my $mode (qw(direct unified)) {
                my $observations = $memory_deltas{$metric}{$mode};
                $memory_summary{$metric . '_' . $mode . '_delta_kib'} =
                    $observations && @$observations
                    ? median(@$observations) : undef;
            }
            my $direct = $memory_summary{$metric . '_direct_delta_kib'};
            my $unified = $memory_summary{$metric . '_unified_delta_kib'};
            $memory_summary{$metric . '_unified_minus_direct_kib'} =
                defined($direct) && defined($unified)
                ? $unified - $direct : undef;
        }
        $cases{$case->{id}} = {
            ratio => $summary->{median_paired_wall_ratio},
            minimum => $summary->{min_paired_wall_ratio},
            maximum => $summary->{max_paired_wall_ratio},
            cpu_ratio => $summary->{median_paired_cpu_ratio},
            setup_delta_us => $summary->{median_request_delta_us},
            p95_delta_us => median(
                map { $_->{p95_delta_us} } @{$summary->{paired}}),
            p99_delta_us => median(
                map { $_->{p99_delta_us} } @{$summary->{paired}}),
            %memory_summary,
        };
    }
    return { manifest => $manifest, cases => \%cases };
}

my ($first_dir, $second_dir) = @ARGV;
my $first_real = abs_path($first_dir)
    or die "first sweep directory not found: $first_dir\n";
my $second_real = abs_path($second_dir)
    or die "second sweep directory not found: $second_dir\n";
die "two independent sweep directories are required\n"
    if $first_real eq $second_real;
my $first = load_sweep($first_dir);
my $second = load_sweep($second_dir);
my $host_a = $first->{manifest}{host};
my $host_b = $second->{manifest}{host};
for my $key (qw(perl archname cpu_model cpu_governor
                upper_commit net_quic_version)) {
    die "incompatible host $key\n" unless same($host_a->{$key}, $host_b->{$key});
}
for my $index (0, 2, 4) {
    die "incompatible uname field $index\n"
        unless ref($host_a->{uname}) eq 'ARRAY'
            && ref($host_b->{uname}) eq 'ARRAY'
            && same($host_a->{uname}[$index], $host_b->{uname}[$index]);
}
for my $key (qw(samples warmup rounds)) {
    die "incompatible workload $key\n"
        unless same($first->{manifest}{workload}{$key},
            $second->{manifest}{workload}{$key});
}
my @ids = sort keys %{$first->{cases}};
my @other = sort keys %{$second->{cases}};
die "incompatible scenario sets\n"
    unless join("\0", @ids) eq join("\0", @other);
my @rows;
for my $id (@ids) {
    my ($a, $b) = ($first->{cases}{$id}, $second->{cases}{$id});
    my $changed_direction = ($a->{ratio} - 1) * ($b->{ratio} - 1) < 0;
    push @rows, {
        id => $id, first => $a, second => $b,
        ratio_change => $b->{ratio} - $a->{ratio},
        direction_change => $changed_direction
            ? JSON::PP::true : JSON::PP::false,
    };
    printf "%s wall_ratio=%.4f [%.4f..%.4f] vs %.4f [%.4f..%.4f]"
        . " change=%+.4f reversed=%s"
        . " cpu_ratio=%s/%s setup_delta_us=%.2f/%.2f"
        . " p95_delta_us=%.1f/%.1f p99_delta_us=%.1f/%.1f"
        . " rss_u_minus_d_kib=%s/%s"
        . " pss_u_minus_d_kib=%s/%s"
        . " private_u_minus_d_kib=%s/%s"
        . " private_direct_unified_kib=%s,%s/%s,%s\n",
        $id, $a->{ratio}, $a->{minimum}, $a->{maximum},
        $b->{ratio}, $b->{minimum}, $b->{maximum},
        $b->{ratio} - $a->{ratio}, $changed_direction ? 'yes' : 'no',
        (defined($a->{cpu_ratio}) ? sprintf('%.4f', $a->{cpu_ratio}) : 'NA'),
        (defined($b->{cpu_ratio}) ? sprintf('%.4f', $b->{cpu_ratio}) : 'NA'),
        $a->{setup_delta_us}, $b->{setup_delta_us},
        $a->{p95_delta_us}, $b->{p95_delta_us},
        $a->{p99_delta_us}, $b->{p99_delta_us},
        display_delta($a->{rss_unified_minus_direct_kib}),
        display_delta($b->{rss_unified_minus_direct_kib}),
        display_delta($a->{pss_unified_minus_direct_kib}),
        display_delta($b->{pss_unified_minus_direct_kib}),
        display_delta($a->{private_unified_minus_direct_kib}),
        display_delta($b->{private_unified_minus_direct_kib}),
        display_delta($a->{private_direct_delta_kib}),
        display_delta($a->{private_unified_delta_kib}),
        display_delta($b->{private_direct_delta_kib}),
        display_delta($b->{private_unified_delta_kib});
}
my $reversals = grep { $_->{direction_change} } @rows;
print "# ratio direction reversals: $reversals/" . scalar(@rows) . "\n";
print "# exploratory only: not a speed or memory-allocation regression gate\n";
if (defined $json_output) {
    die "empty JSON destination\n" unless length $json_output;
    open my $fh, '>', $json_output or die "cannot open $json_output: $!\n";
    print {$fh} JSON::PP->new->canonical->pretty->encode({
        schema_version => 1,
        first_dir => $first_dir, second_dir => $second_dir,
        cases => \@rows, direction_changes => $reversals,
    }) or die "cannot write $json_output: $!\n";
    close $fh or die "cannot close $json_output: $!\n";
}
