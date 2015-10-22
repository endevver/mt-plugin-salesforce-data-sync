package SalesforceDataSync::Task;

use strict;
use warnings;

use SalesforceDataSync::Sync;

# Part of the MT tasks framework, this is what lets the sync happen
# automatically.
sub task {
    my $app    = MT->instance;
    my $plugin = $app->component('SalesforceDataSync');

    # Log in and get a session ID.
    my $sid = SalesforceDataSync::Sync::_get_session_id();

    # Process the SF sync definitions.
    SalesforceDataSync::Sync::_process_sync_defs({
        sid => $sid,
    });
}

1;

__END__
