package SalesforceDataSync::Sync;

use strict;
use warnings;

use WWW::Salesforce;
use WWW::Mechanize;
use JSON;
use MT::Util qw( ts2epoch epoch2ts offset_time_list );

# Log in to Salesforce and get a session ID.
sub _get_session_id {
    my $app = MT->instance;

    my $username = $app->config->SalesforceDataSyncUsername
        || die 'No SalesforceDataSyncUsername defined!';

    my $password = $app->config->SalesforceDataSyncPassword
        || die 'No SalesforceDataSyncPassword defined!';

    # Log in
    my $sforce = eval {
        WWW::Salesforce->login(
            username => $username,
            password => $password,
        );
    };

    die "Could not login to SFDC: $@" if $@;

    # Give the session ID back.
    return $sforce->{sf_sid};
}

# Take a look at each of the SF sync definitions that have been defined. Build
# the necessary query, and sync any results.
sub _process_sync_defs {
    my ($arg_ref) = @_;
    my $sid       = $arg_ref->{sid};
    my $app       = MT->instance;
    my $plugin    = $app->component('SalesforceDataSync');

    # Note when this processing started. Save this value after all definitions
    # have been processed. Next time content is queried we'll use this to limit
    # queries.
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time);
    $year += 1900;
    $mon  += 1;
    # Create the format of yyyy-mm-ddThh:mm:ssZ
    my $start_ts = $year . '-' . sprintf("%02d", $mon) . '-'
        . sprintf("%02d", $mday)
        . 'T' . sprintf("%02d", $hour) . ':' . sprintf("%02d", $min) . ':'
        . sprintf("%02d", $sec) . 'Z';

    # Get the previously-saved time limiter and use it to limit the query to
    # recently-updated content from the time previously checked.
    my $saved_ts = $plugin->get_config_value('last_updated', 'system');
    my $query_time_limiter = $saved_ts
        ? '+AND+LastModifiedDate>' . $saved_ts
        : '';

    # Build an array of hashes of the loaded data sync definitions, which can
    # be used to build the picker on the listing screen.
    my $sf_data_defs = $app->registry('salesforce_data_sync');

    foreach my $sf_data_def ( keys %{$sf_data_defs} ) {
        _process_sync_def({
            sf_data_defs       => $sf_data_defs,
            sf_data_def        => $sf_data_def,
            sid                => $sid,
            query_time_limiter => $query_time_limiter,
            republish          => 1,
        });
    }

    # Save the time. Future requests will only look for updated
    # content between now and the future request.
    $plugin->set_config_value('last_updated', $start_ts);
}

# Process a single sync definition.
sub _process_sync_def {
    my ($arg_ref)          = @_;
    my $sf_data_defs       = $arg_ref->{sf_data_defs};
    my $sf_data_def        = $arg_ref->{sf_data_def};
    my $sid                = $arg_ref->{sid};
    my $query_time_limiter = $arg_ref->{query_time_limiter};
    my $republish          = $arg_ref->{republish};
    my $app                = MT->instance;
    my $plugin             = $app->component('SalesforceDataSync');

    # Can't find the definition? Just give up!
    if ( !$sf_data_defs->{ $sf_data_def } ) {
        $app->log({
            category => 'SF Data Sync definition',
            class    => 'salesforcedatasync',
            level    => $app->model('log')->ERROR(),
            message  => 'The Salesforce Data Sync definition ID &ldquo;'
                . $sf_data_def . '&rdquo; could not be found. Sync could '
                . 'not continue.',
        });

        # Process the next definition.
        return;
    }

    # Save the SF data sync definition for later use with each record to be
    # synced.
    my $definition = $sf_data_defs->{ $sf_data_def };
    my $sf_url     = $definition->{api_base_url}
        || 'https://na13.salesforce.com';

    # Syncs normally happen automatically. Skip this one if automatic sync has
    # specifically been disabled.
    if (
        $definition->{automatic_sync}
        && $definition->{automatic_sync} eq '0'
    ) {
        $app->log({
            category => 'SF Data Sync definition',
            class    => 'salesforcedatasync',
            level    => $app->model('log')->INFO(),
            message  => 'The Salesforce Data Sync definition &ldquo;'
                . $definition->{definition_name} . '&rdquo; is not '
                . 'automatically synced. Skipping this definition.',
        });

        # Process the next definition.
        return;
    }

    # Check for the blog to which the data should be synced.
    if ( !$definition->{blog_name} ) {
        $app->log({
            category => 'SF Data Sync definition',
            class    => 'salesforcedatasync',
            level    => $app->model('log')->ERROR(),
            message  => 'The Salesforce Data Sync definition &ldquo;'
                . $definition->{definition_name} . '&rdquo; did not include '
                . 'a blog name, which is a required value. Sync could '
                . 'not continue.',
        });

        # Process the next definition.
        return;
    }

    my $blog = $app->model('blog')->load({
        name => $definition->{blog_name},
    });

    # No blog found? Give up processing this definition -- we need a
    # destination to sync to. Proceed to the next definition.
    if ( !$blog ) {
        my $message = 'The Salesforce Data Sync definition &ldquo;'
            . $definition->{definition_name} . '&rdquo; referenced the '
            . 'blog named &ldquo;' . $definition->{blog_name}
            . ',&rdquo; however this blog could not be found. Sync could '
            . 'not continue.';

        $app->log({
            category => 'SF Data Sync definition',
            class    => 'salesforcedatasync',
            level    => $app->model('log')->ERROR(),
            message  => $message,
        });

        # Process the next definition.
        return;
    }

    # Assemble the various options set in the definition.
    my $query = 'SELECT+name+from+Account';
    $query .= $definition->{sf_base_query}
        ? '+' . $definition->{sf_base_query} : '';

    # Add the time limiter to only get data newer than the previous sync. This
    # is empty if the sync was manually started or if a sync has never been run.
    $query .= $query_time_limiter;

    my $mech = WWW::Mechanize->new();
    $mech->agent('Mozilla/5.0');
    $mech->add_header( "Authorization" => 'Bearer ' . $sid );

    # Submit the query.
    $mech->get( $sf_url . "/services/data/v23.0/query?q=" . $query );

    # Convert the JSON result into a hash.
    my $result = {};
    eval { $result = JSON::from_json( $mech->content ) };

    # Any results?
    if ( $result->{totalSize} == 0 ) {
        $app->log({
            category => 'SF Data Sync definition',
            class    => 'salesforcedatasync',
            blog_id  => $blog->id,
            level    => $app->model('log')->INFO(),
            message  => 'The Salesforce Data Sync definition &ldquo;'
                . $definition->{definition_name} . '&rdquo; completed but '
                . 'found zero (0) records to sync.',
        });
    }

    my $counter = 0;
    my $next_records_url;
    my $done = 0;

    # Queries are generally limited to 2000 records. `done` will be true if
    # fewer than 2000 records are returned or if the last batch returend the
    # last of the group for a given query.
    while ( $done == 0 ) {
        # If the $next_records_url was set that means there are more records to
        # handle.
        if ( $next_records_url ) {
            # Submit the query.
            $mech->get( $sf_url . $next_records_url );

            # Convert the JSON result into a hash.
            eval { $result = JSON::from_json( $mech->content ) };
        }

        # Get the individual school records so that each can be processed.
        my $records = $result->{records};
        foreach my $record ( @$records ) {
            # A $record is a hash in the format:
            #     {
            #         'Name' => '[Friendly object name]',
            #         'attributes' => {
            #             'type' => 'Account',
            #             'url' => '/services/data/v23.0/sobjects/Account/[SF object ID]'
            #         }
            #     }

            # Each record should become a Schwartz job. Insert the worker, and
            # count how many there are.
            $counter += _inject_worker({
                record_url    => $record->{attributes}->{url},
                record_name   => $record->{Name},
                blog_id       => $blog->id,
                definition_id => $sf_data_def,
                republish     => $republish,
                # Just in case this record is already in the queue, let's note it
                # so that it doesn't seem the sync is completely failing.
                log_message   => 'The Salesforce Data Sync definition &ldquo;'
                    . $definition->{definition_name} . '&rdquo; found that a '
                    . 'record for `' . $record->{attributes}->{url} . '`, &ldquo;'
                    . $record->{Name} . '&rdquo; is already inserted in the queue; '
                    . 'another will not be added.',
            });
        }

        # Are there more records to process? 
        if ( $result->{done} eq 'true' ) {
            $done = 1;
        }
        # Save the `nextRecordsUrl` so that a query can be submitted for the
        # next batch.
        else {
            $next_records_url = $result->{nextRecordsUrl}
                ? $result->{nextRecordsUrl}
                : undef;
        }
    }

    if ( $counter ) {
        my $dated_message_insert = $query_time_limiter
            ? ' since last queued at '
                . $plugin->get_config_value('last_run_' . $sf_data_def) . '.'
            : '.';
        my $message = 'The Salesforce Data Sync definition &ldquo;'
            . $definition->{definition_name} . '&rdquo; added '
            . $counter . ' jobs to the queue' . $dated_message_insert;
        $app->log({
            category => 'SF Data Sync definition',
            class    => 'salesforcedatasync',
            blog_id  => $blog->id,
            level    => $app->model('log')->INFO(),
            message  => $message,
        });
    }

    # Note when this sync was last run. This should be obvious from Log
    # activity but that can be overwhelming. We just want to note when the sync
    # last ran for an easy-to-read display.
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    $year += 1900;
    $mon  += 1;
    # Create the format of yyyy-mm-dd hh:mm:ss
    my $last_run = $year . '-' . sprintf("%02d", $mon) . '-'
        . sprintf("%02d", $mday)
        . ' ' . sprintf("%02d", $hour) . ':' . sprintf("%02d", $min) . ':'
        . sprintf("%02d", $sec);

    $plugin->set_config_value(
        'last_run_' . $sf_data_def,
        $last_run
    );
}

# Any records found when processing the definitions should be used to create a
# Schwartz job. That then lets each record be processed individually and is near
# bulletproof against things like server timeouts.
sub _inject_worker {
    my ($arg_ref)     = @_;
    my $record_url    = $arg_ref->{record_url};
    my $record_name   = $arg_ref->{record_name};
    my $blog_id       = $arg_ref->{blog_id};
    my $definition_id = $arg_ref->{definition_id};
    my $republish     = $arg_ref->{republish};
    my $log_message   = $arg_ref->{log_message};
    my $app           = MT->instance;

    # The coalesce value is in the format:
    #     [blog ID]:[definition ID]:[record URL]:[republish preference]
    my $coalesce = $blog_id . ':' . $definition_id . ':' . $record_url . ':'
        . $republish;

    # Is there already a job with this record URL? No need to add another if so.
    # If this job is already in the queue, note it in the Activity Log so that
    # it doesn't seem like the sync skipped over the job.
    if ( $app->model('ts_job')->exist({ coalesce => $coalesce }) ) {
        $app->log({
            category => 'SF Data Sync inject worker',
            class    => 'salesforcedatasync',
            blog_id  => $blog_id,
            level    => $app->model('log')->INFO(),
            message  => $log_message,
        });
        return 0;
    }

    require TheSchwartz::Job;
    require MT::TheSchwartz;

    my $job = TheSchwartz::Job->new();
    $job->funcname( 'SalesforceDataSync::Worker' );
    $job->coalesce( $coalesce );
    $job->uniqkey( $record_name );
    $job->priority( 1 ); # Lowest priority

    # Insert the job into the queue.
    MT::TheSchwartz->insert( $job );

    return 1; # Let's count the successful addition of the worker.
}


# Sync an individual record to an entry/page object. Most typically, this
# process is called by the SalesforceDataSync:::Worker.
sub sync_record {
    my ($arg_ref)  = @_;
    my $record_url = $arg_ref->{record_url};
    my $definition = $arg_ref->{definition};
    my $blog_id    = $arg_ref->{blog_id};
    my $republish  = $arg_ref->{republish};
    my $app        = MT->instance;
    my $blog       = $app->model('blog')->load({ id => $blog_id, });

    my $sf_url       = $definition->{api_base_url};
    my $obj_type     = $definition->{obj_type};
    my $mt_id_field  = $definition->{mt_id_field};
    my $sf_id_field  = $definition->{sf_id_field};
    # Log message default values, presuming that an entry is being updated.
    my $log_msg      = 'Salesforce data sync definition &ldquo;'
        . $definition->{definition_name} . '&rdquo; ';

    # Submit the query for the record data.
    my $sid = _get_session_id($app);
    my $mech = WWW::Mechanize->new();
    $mech->agent('Mozilla/5.0');
    $mech->add_header( "Authorization" => 'Bearer ' . $sid );
    $mech->get( $sf_url . $record_url );

    # Convert the JSON result into a hash.
    my $sf_data = {};
    eval { $sf_data = JSON::from_json( $mech->content ) };

    # Look for an existing entry/page object that can be updated with the new
    # data.
    my @objects = $app->model( $obj_type )->search_by_meta(
        $mt_id_field,
        $sf_data->{ $sf_id_field },
    );

    # There must be a better way to do this, right? Get the object, if found.
    my $iter = sub { return shift @objects; };
    my $obj  = $iter->();

    if ( $obj ) {
        $log_msg .= "found $obj_type " . $obj->id
            . ' (' . $sf_data->{Name} . ') ';
    }
    # No object found? Create a new one.
    else {
        $obj = $app->model( $obj_type )->new();
        $obj->blog_id( $blog->id );
        # An author needs to own the object.
        $obj->author_id(0);
        # Set entry status to unpublished by default.
        $obj->status( $app->model('entry')->HOLD() );

        $log_msg .= "created an $obj_type " . ' (' . $sf_data->{Name} . ') ';
    }

    # Sync data!
    foreach my $mt_field_name ( keys %{$definition->{fields}} ) {
        # Why does a "plugin" hash show up under the `fields` key? Just ignore
        # it; there's no field named "plugin" and a Custom Field can't use that
        # name, either. (A CF would be `field.plugin`.)
        next if $mt_field_name eq 'plugin';

        # This MT field should be updated with any new SF content. Also
        # responsible for determing if the entry should be published.
        _sync_field_content({
            mt_field_name => $mt_field_name,
            definition    => $definition,
            sf_data       => $sf_data,
            object        => $obj,
        });
    }

    # Note when this object was updated. Potentially useful to see when future
    # resyncs happen.
    my @ts = offset_time_list( time, $blog );
    my $ts = sprintf '%04d%02d%02d%02d%02d%02d',
        $ts[5] + 1900, $ts[4] + 1, @ts[ 3, 2, 1, 0 ];
    $obj->modified_on( $ts );

    # Data has been synced. Save the entry.
    if ( $obj->save ) {
        $app->log({
            category => $obj_type, # Will be `entry` or `page`
            class    => 'salesforcedatasync',
            blog_id  => $obj->blog_id,
            level    => $app->model('log')->WARNING(),
            message  => $log_msg . 'and synced data to it.',
        });
    }
    # Trouble saving the object?
    else {
        die $obj->errstr;
    }

    # Republish the entry by default, with dependencies (archives, indexes) by
    # default. This can be overridden in the YAML definition.
    if ($republish) {
        my $build_dependencies = $definition->{build_dependencies} || 1;
        $app->rebuild_entry(
            Entry             => $obj,
            BuildDependencies => $build_dependencies,
        );
    }
}

# The current MT field should be updated with any new SF data.
sub _sync_field_content {
    my ($arg_ref)     = @_;
    my $mt_field_name = $arg_ref->{mt_field_name};
    my $definition    = $arg_ref->{definition};
    my $sf_data       = $arg_ref->{sf_data};
    my $obj           = $arg_ref->{object};
    my $obj_type      = $obj->class;
    my $app           = MT->instance;

    my $sf_field_name  = $definition->{fields}->{ $mt_field_name };
    my $sf_field_value = '';

    # Prepare the SF field data to be written to an MT field.
    # This is an array of fields. String them all together with the
    # `separator` to make a single value to be saved to $mt_field_name.
    if (
        ref($sf_field_name) eq 'HASH'
        && $sf_field_name->{fields}
    ) {
        my $separator = $sf_field_name->{separator};
        my (@field_names, @field_values);
        foreach my $field ( @{$sf_field_name->{fields}} ) {
            my $field_value = '';
            if ( ref($field) eq 'HASH' ) {
                my $field_name = (keys $field)[0];
                push @field_names, $field_name;
                $field_value = $sf_data->{ $field_name };
            } else {
                push @field_names, $field;
                $field_value = $sf_data->{ $field };
            }

            my $value = _build_sf_field_value({
                sf_field_name  => $field,
                sf_field_value => $field_value,
            });

            # If a value was found/returned add it to the array of values to be
            # turned into a string later.
            push @field_values, $value
                if $value;
        }

        # Build a string of the data to be saved in the MT field.
        $sf_field_value = join($separator, @field_values);

        # Build a string of the SF field names to be used in case it needs
        # to be logged.
        $sf_field_name = 'array of fields: ' . join(', ', @field_names);
    }

    # This is just a simple field definition, mapping an MT field to an SF field
    # and copying whatever data might be coming from SF.
    else {
        $sf_field_value = _build_sf_field_value({
            sf_field_name  => $sf_field_name,
            sf_field_value => $sf_data->{ $sf_field_name },
        });
    }

    # Found the MT field that was identified in the sync definition.
    if ( $obj->has_column( $mt_field_name ) ) {
        # Set the field data in the MT field.
        $obj->$mt_field_name( $sf_field_value );

        # Set whether this object should be published or unpublished by
        # checking for the `publish_control` definition.
        _publish_control({
            definition    => $definition,
            mt_field_name => $mt_field_name,
            object        => $obj,
        });
    }
    # Did *not* find the MT field that was identified in the sync
    # definition.
    else {
        $app->log({
            category => 'Salesforce Data Sync',
            class    => 'salesforcedatasync',
            blog_id  => $obj->blog_id,
            level    => $app->model('log')->WARNING(),
            message  => 'The Salesforce Data Sync definition &ldquo;'
                . $definition->{definition_name} . '&rdquo; referenced the '
                . 'Movable Type field &ldquo;' . $mt_field_name
                . '&rdquo; of the object type &ldquo;' . $obj_type
                . ',&rdquo; however this field could not be found. Sync '
                . 'will continue, however the Salesforce data in field '
                . '&ldquo;' . $sf_field_name
                . '&rdquo; will not be synced.',
        });
    }
}

# Determine what the SF field value is. This may simply be the SF field
# contents, or it may need to be built with the data sync definition.
sub _build_sf_field_value {
    my ($arg_ref)   = @_;
    my $field_name  = $arg_ref->{sf_field_name};
    my $field_value = $arg_ref->{sf_field_value};
    my $value       = '';

    # A `value` is defined for this field in the SF data sync definition.
    # Determine if the SF data is true/false; if true, return `value` otherwise
    # the field is empty.
    if ( ref($field_name) eq 'HASH' ) {
        my $key = (keys $field_name)[0];
        my $default_value = $field_name->{ $key }->{value};

        if ( $default_value ) {
            $value = $field_value && $field_value eq 'true'
                ? $default_value
                : '';
        }
    }
    # A `value` is not defined for this field in the SF data sync definition,
    # which simply means that the field's value is what should be synced to MT.
    else {
        $value = $field_value;
    }

    return $value;
}

# Should this entry/page object be published? If the SF definition defined a
# "publish control" field, use it to check if the desired field value matches
# the saved field value. If it does match, then the entry should be set to
# publish.
sub _publish_control {
    my ($arg_ref)     = @_;
    my $definition    = $arg_ref->{definition};
    my $mt_field_name = $arg_ref->{mt_field_name};
    my $obj           = $arg_ref->{object};
    my $obj_type      = $obj->class;
    my $app           = MT->instance;

    # Give up if publish control hasn't been defined. Entries should always be
    # in the default unpublished state.
    return if !$definition->{publish_control};

    # If this is not the identified publish control field, skip it.
    return if $definition->{publish_control}->{field} ne $mt_field_name;

    # This is the right field to check for the publish control. Now check the
    # the value to determine the publish option.
    my $status = $obj->$mt_field_name
        && $obj->$mt_field_name eq $definition->{publish_control}->{value}
            ? $app->model( $obj_type )->RELEASE()
            : $app->model( $obj_type )->HOLD();

    $obj->status( $status );
}

1;

__END__
