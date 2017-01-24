package SalesforceDataSync::CMS;

use strict;
use warnings;

use SalesforceDataSync::Sync;

# This is the listing page, at Tools > Salesforce Data Sync.
sub list_data_sync_definitions {
    my $app    = shift;
    my $plugin = $app->component('SalesforceDataSync');
    my $param  = {};

    # Build an array of hashes of the loaded data sync definitions, which can
    # be used to build the picker on the listing screen.
    my $sf_data_defs = $app->registry('salesforce_data_sync');
    my @parsed;
    foreach my $sf_data_def (
        sort {
            &{ $sf_data_defs->{$a}->{definition_name} }
            cmp &{ $sf_data_defs->{$b}->{definition_name} }
        }
            keys %{$sf_data_defs}
    ) {
        my $definition = $sf_data_defs->{$sf_data_def};

        my $description = '';
        if ( $definition->{blog_name} ) {
            my $blog = $app->model('blog')->load({
                name => $definition->{blog_name}
            });

            if ( $blog ) {
                $description = 'Syncs '
                    . $definition->{obj_type} . ' objects to '
                    . $blog->name . '.';
            }
            else {
                $description = '<div class="error">The blog defined by '
                    . '`blog_name`, &ldquo;' . $definition->{blog_name}
                    . '&rdquo; does not exist!</div>';
            }
        } else {
            $description = '<div class="error">`blog_name` not defined!</div>';
        }

        # When was this sync last run?
        my $last_run = $plugin->get_config_value(
            'last_run_' . $sf_data_def,
            'system'
        ) || 'Never run';

        # Syncs normally happen automatically; then need to be explicitly
        # disabled in YAML.
        my $auto_sync = $definition->{automatic_sync}
            && $definition->{automatic_sync} eq '0'
            ? 'Disabled'
            : 'Enabled';

        push @parsed, {
            def_id      => $sf_data_def,
            label       => $definition->{definition_name},
            description => $description,
            last_run    => $last_run,
            auto_sync   => $auto_sync,
        };
    }

    $param->{defs} = \@parsed;

    $param->{log_queries} = $plugin->get_config_value('log_queries');

    return $plugin->load_tmpl('list_defs.mtml', $param);
}

# This is the dialog that appears when the "Run Complete Sync" button is pressed
# on the listing screen.
sub start_sync_dialog {
    my $app    = shift;
    my $plugin = $app->component('SalesforceDataSync');
    my $q      = $app->can('query') ? $app->query : $app->param;
    my $param  = {};

    # Find the sync definition.
    my $def_id = $q->param('def_id');
    my $definition = $app->registry('salesforce_data_sync', $def_id);

    # Show the Republish During Data Sync override?
    $param->{republish} = $definition->{republish}
        && $definition->{republish} eq '1'
        ? 1
        : 0;

    $param->{def_id}    = $def_id;
    $param->{label}     = $definition->{definition_name};
    $param->{blog_name} = $definition->{blog_name};

    return $plugin->load_tmpl('start_sync.mtml', $param);
}

# Use has clicked to run a complete sync for a given definition.
sub start_complete_sync {
    my $app    = shift;
    my $plugin = $app->component('SalesforceDataSync');
    my $q      = $app->can('query') ? $app->query : $app->param;

    # Log in and get a session ID.
    my $sid = SalesforceDataSync::Sync::_get_session_id();

    my $sf_data_defs = $app->registry('salesforce_data_sync');
    my $def_id       = $q->param('def_id');

    # Republishing during a complete sync is disabled by default, but can be
    # enabled if preferred.
    my $republish = $q->param('republish') || 0;

    SalesforceDataSync::Sync::_process_sync_def({
        sf_data_defs => $sf_data_defs,
        sf_data_def  => $def_id,
        sid          => $sid,
        republish    => $republish,
    });

    my $param = {
        label => $sf_data_defs->{ $def_id }->{definition_name},
    };
    return $plugin->load_tmpl('start_sync_started.mtml', $param);
}

# System filters used in the Activity Log.
sub system_filters {
    return {
        salesforcedatasync_activity => {
            label => 'Salesforce Data Sync activity',
            items => [
                {
                    type => 'class',
                    args => { value => 'salesforcedatasync' },
                },
            ],
            order => 500,
        },
        salesforcedatasync_warnings => {
            label => 'Salesforce Data Sync warnings',
            items => [
                {
                    type => 'class',
                    args => { value => 'salesforcedatasync' },
                },
                {
                    type => 'level',
                    args => { value => MT::Log::WARNING() },
                },
            ],
            order => 501,
        },
        salesforcedatasync_errors => {
            label => 'Salesforce Data Sync errors',
            items => [
                {
                    type => 'class',
                    args => { value => 'salesforcedatasync' },
                },
                {
                    type => 'level',
                    args => { value => MT::Log::ERROR() },
                },
            ],
            order => 502,
        },
        salesforcedatasync_queries => {
            label => 'Salesforce Data Sync Salesforce queries',
            items => [
                {
                    type => 'class',
                    args => { value => 'salesforcedatasync' },
                },
                {
                    type => 'category',
                    args => {
                        option => 'contains',
                        string => 'Salesforce Data Sync Query',
                    },
                },
            ],
            order => 503,
            condition => sub {
                # Only show if Log Queries is enabled in plugin settings
                my $plugin = MT->component('SalesforceDataSync');
                return 1 if $plugin->get_config_value('log_queries');
                return 0;
            },
        },
    };
}

# This is the "Manually Resync Salesforce Data" plugin action on the Manage
# Entries screen, which will resync data for the selected entries.
sub list_action_entry {
    my ($app) = @_;
    $app->validate_magic or return;

    my $q       = $app->can('query') ? $app->query : $app->param;
    my @obj_ids = $q->param('id');

    foreach my $obj_id (@obj_ids) {
        _action_sync({
            obj_id => $obj_id,
        });
    }

    $app->call_return;
}

# This is the "Manually Resync Salesforce Data" plugin action on the Edit Entry
# screen, which will resync data for the current entry.
sub page_action_entry {
    my ($app) = @_;
    $app->validate_magic or return;

    my $q      = $app->can('query') ? $app->query : $app->param;
    my $obj_id = $q->param('id');

    _action_sync({
        obj_id => $obj_id,
    });

    $app->call_return;
}

# List actions and page actions basically use the same process.
sub _action_sync {
    my ($arg_ref) = @_;
    my $obj_id    = $arg_ref->{obj_id};
    my $app       = MT->instance;

    my $obj  = $app->model('entry')->load( $obj_id );
    my $blog = $app->model('blog')->load( $obj->blog_id );

    # Find the SF definition for this blog.
    my $sf_data_defs = $app->registry('salesforce_data_sync');
    my $definition = {};
    foreach my $sf_data_def ( keys %{$sf_data_defs} ) {
        # Is this the definition we're looking for? If so, give up.
        if ( $sf_data_defs->{ $sf_data_def}->{blog_name} eq $blog->name ) {
            $definition = $sf_data_defs->{ $sf_data_def};
            last;
        }
    }

    my $mt_id_field  = $definition->{mt_id_field};

    # Is there a SF ID for this entry? If not, skip it.
    next unless $obj->has_column( $mt_id_field ) && $obj->$mt_id_field;

    my $record_url = '/services/data/v23.0/sobjects/Account/'
        . $obj->$mt_id_field;

    SalesforceDataSync::Sync::sync_record({
        record_url => $record_url,
        definition => $definition,
        blog_id    => $blog->id,
        republish  => 1,
    });
}

# Should the "Manually Resync Salesforce Data" link be shown on this screen?
# This is used for Page Actions and List Actions.
sub action_condition {
    my $app = MT->instance;

    return 0 unless $app->blog;

    my $blog = $app->blog;

    my $sf_data_defs = $app->registry('salesforce_data_sync');
    my $definition = {};
    foreach my $sf_data_def ( keys %{$sf_data_defs} ) {
        # Is this the definition we're looking for? If so, give up.
        if ( $sf_data_defs->{ $sf_data_def}->{blog_name} eq $blog->name ) {
            return 1;
        }
    }

    return 0;
}

1;

__END__
