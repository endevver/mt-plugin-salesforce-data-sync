package SalesforceDataSync::Worker;

use strict;
use warnings;

use base qw( TheSchwartz::Worker );

use TheSchwartz::Job;
use Time::HiRes qw(gettimeofday tv_interval);
use SalesforceDataSync::Sync;

sub keep_exit_status_for { 1 }
sub grab_for { 30 }
sub max_retries { 10 }
sub retry_delay { 60 }

sub work {
    my $class = shift;
    my TheSchwartz::Job $job = shift;
    my $s = MT::TheSchwartz->instance();
    my $app = MT->instance;

    my @jobs;
    push @jobs, $job;
    if (my $key = $job->coalesce) {
        while (my $job = $s->find_job_with_coalescing_value($class, $key)) {
            push @jobs, $job;
        }
    }

    foreach $job (@jobs) {
        my @values        = split(':', $job->coalesce);
        my $blog_id       = $values[0];
        # The SF definition ID used in the registry.
        my $definition_id = $values[1];
        my $record_url    = $values[2];
        # Republish is just a boolean value to signal for later use.
        my $republish     = $values[3];

        # Use the definition ID to find the definition hash in the registry.
        my $definition = $app->registry('salesforce_data_sync', $definition_id);
        next if !$definition;

        # Call sync_record, which does the actual work of syncing a record from
        # SF to MT.
        SalesforceDataSync::Sync::sync_record({
            record_url => $record_url,
            definition => $definition,
            blog_id    => $blog_id,
            republish  => $republish,
        });
    }

    return $job->completed();
}

1;

__END__
