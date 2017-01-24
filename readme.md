# Salesforce Data Sync Plugin for Movable Type

This plugin makes it easy to synchronize Salesforce data to Movable Type. After
defining the Salesforce source and Movable Type destination in YAML, this
plugin can copy content into MT. Using the [Salesforce REST API](https://developer.salesforce.com/docs/atlas.en-us.api_rest.meta/api_rest/),
content can be copied automatically at scheduled intervals or manually
triggered. Multiple SF data sources can be specified, as well.

Salesforce records are inserted as Schwartz jobs (more commonly referred to as
the "Publish Queue") and sync activity is recorded to the Activity Log,
providing lots of insight into how your data sync is providing.


# Requirements

* Perl modules WWW::Salesforce and WWW::Mechanize

* Movable Type 6+

* A Salesforce Connected App set up with the data you want to share and a user
  with permission to access it.

* `run-periodic-tasks` must be set up.

While not required, the [Publish Queue Manager](https://github.com/endevver/mt-plugin-pqmanager/releases)
plugin is very helpful to monitor sync activity.


# Configuration

Two Configuration Directives need to be added to `mt-config.cgi`:

* `SalesforceDataSyncUsername`: the username of the Salesforce user with access
  to the data.
* `SalesforceDataSyncPassword`: the password of the Salesforce user with access
  to the data.

YAML is used to define how the synchronization should happen. The following is
a simple example.

    salesforce_data_sync:
        my_sf_data:
            definition_name: 'My Awesome Salesforce Data'
            api_base_url: 'https://na13.salesforce.com'
            obj_type: entry
            blog_name: 'My Awesome Blog'
            sf_id_field: Id
            mt_id_field: field.salesforce_id
            fields:
                title: Name
                text: ExplanationOfAwesomeness
                field.contact: ContactInformation
                field.salesforce_id: Id

Create your own source within the `salesforce_data_sync` object with a sync
definition. In this example the sync definition is `my_sf_data`. Any number of
sync definitions can be specified. Many keys are children of this definition,
detailed below.

The first key in the example is `definition_name`, which is really just a
friendly name for your definition, mostly used in logging activity. This is
required.

In the System Overview > Plugins settings screen you'll see an option to record
the Salesforce queries to the Activity Log. With this option enabled, you can
filter the Activity Log to show only SF queries -- use the "Salesforce Data Sync
Salesforce queries" System Filter.

## Sync Source and Destination Configuration

The `api_base_url` is required. The SF user will have a URL to authenticate to,
which is this value.

Where in Movable Type should the Salesforce data be saved? This is defined with
two keys, both required:

* `blog_name`: Enter the name of the destination blog. (Using the name instead
  of the ID makes it easy to set up multiple environments [that may use
  different blog IDs] to work with the same content.)

* `obj_type`: Enter a valid MT object type; `entry` is almost definitely the
  object type you want to use.

A given Salesforce record and Movable Type object need to know that they
reference the same data in order for records to be updated (as opposed to be
recreated anew) during subsequent syncs. This is managed with two keys, both
required:

* `sf_id_field`: A unique field in Salesforce. The `Id` field is a good choice;
  Salesforce automatically maintains it.

* `mt_id_field`: specify a field for the destination of the SF field contents
  (in the example, the `Id` field). Note that this *is not and can not* be
  Movable Type's `id` field! Most likely, you want to create a text Custom
  Field for this data. Refer to the Custom Field information in the Mapping
  Fields section below for more information, but in short a good idea is to
  create a new Custom Field with the basename `salesforce_id` of type
  Single-Line Text. The value for the `mt_id_field` can then be
  `field.salesforce_id`.

Do you need to include only a subset of the Salesforce data in Movable Type?
Use the `sf_base_query` key to identify the correct content. Craft a query with
the Salesforce REST API to return the data desired. ([SOQL](https://developer.salesforce.com/docs/atlas.en-us.198.0.soql_sosl.meta/soql_sosl/)
and [Workbench](https://workbench.developerforce.com/) are useful to build and
test a query.) This plugin will take care of getting content in batches, if
necessary, and will also only look for updated content so your query doesn't
need to handle those scenarios. As the key name `sf_base_query` indicates, this
is used as a *base* for the query. This key is optional.

Syncing normally happens automatically. Every 15 minutes a new Task will be
created to check for any updated content since the last sync, and if there
anything new, Schwartz jobs will be created for the SF records. If you don't
want syncing to happen automatically, however, use the `automatic_sync` key and
set it to a value of `0` and your sync job will not update automatically.

## Mapping Fields

Fields in Salesforce need to be mapped to fields in Movable Type. Fields are
mapped in the following format:

    salesforce_data_sync:
        my_sf_data:
            definition_name: 'My Awesome Salesforce Data'
            fields:
                [MT field]: [Salesforce field]

Movable Type's standard and Custom Fields can be specified. Note that Custom
Fields require the `field.` prefix be added to the basename. When creating a
Custom Field for the synced content, use the simplest field types possible:
Single-Line Text (`text`) and Multi-Line Text (`textarea`). Other field types
might be more appropriate or display in a more useful manner, but syncing may
not work or may not sync as expected.

For most data, that's it! Easy! However, there are a few Salesforce fields that
are required to be included in your mapping:

* Noted above in the discussion of `sf_id_field` and `mt_id_field` is the
  requirement of a Salesforce unique field. `Id` is a good choice, but it needs
  to be saved somewhere, such as the suggested `field.salesforce_id`.

* If you use the Publish Control capability (discussed below), that field must
  also be included in the definition's `fields`.

* An entry needs a title; be sure to specify a Salesforce field for the `title`.

* Salesforce provides a field, `LastModifiedDate`, that is automatically
  updated whenever the record is changed. While not required, mapping this
  field provides a great way to know when a given Entry was last updated.

### Complex Field Solutions

To merge several Salesforce fields into a single MT field, use an expanded syntax:

    salesforce_data_sync:
        my_sf_data:
            definition_name: 'My Awesome Salesforce Data'
            fields:
                [MT field]:
                    separator: ', '
                    fields:
                        - [Salesforce field 1]
                        - [Salesforce field 2]
                        - [Salesforce field 3]

The identified fields will be joined (using the `separator` field value) to
form a single value that can be stored in the specified MT field.

If a field has boolean (true/false) values then those values will be synced,
too. (SF returns boolean values as literally "true" and "false.") However, this
is sometimes not actually as helpful as having a named value. Use the `value`
key to specify a value to be synced if the field is true. Buildign on the
previous example where the SF fields "Apple," "Banana," and "Cantaloupe" are
boolean values:

    salesforce_data_sync:
        my_sf_data:
            definition_name: 'My Awesome Salesforce Data'
            fields:
                field.fruit:
                    separator: ', '
                    fields:
                        - Apple
                            value: apple
                        - Banana
                            value: banana
                        - Cantaloupe
                            value: cantaloupe

Without the `value` key these SF fields my be built into a string reading
`false, true, true`. But with the `value` key they can be built into a string
of `banana, cantaloupe` -- far more useful when strictly publishing a list!

## Publish Control

Synced content is unpublished by default. Within your definition use the
`publish_control` key to cause content to publish. An abbreviated xample:

    salesforce_data_sync:
        my_sf_data:
            definition_name: 'My Awesome Salesforce Data'
            publish_control:
                field: field.is_public
                value: 'true'

In this example, an MT Custom Field named "Is Public" is used. If the value of
this field is "true" then the object (perhaps an Entry) should be published.
Note that this requires that the Custom Field `field.is_public` has been
included in the `fields` hash so that data from Salesforce is copied to it. In
this example, Salesforce might provide values of "true" or "false"; Entries
where the Is Public field have a value of "false" would remain unpublished.

# Publishing

For any content that is set to publish, the keys `republish` and
`build_dependencies` provide control over if and how publishing happens after a
sync. These fields are optional and are enabled by default; they only need to
be included to disable their capabilities:

    salesforce_data_sync:
        my_sf_data:
            definition_name: 'My Awesome Salesforce Data'
            republish: 1
            build_dependencies: 0

Of course, if `republish` is disabled ("0") then the `build_dependencies` key
has no impact.

# Use

Salesforce data is automatically synced. You don't *need* to do anything!

## Monitoring Activity

Salesforce data is automatically synced with Movable Type and you can monitor
that activity to understand what is happening (assuming automatic sync hasn't
been disabled). The following process is how content is synced to Movable Type:

1. A data sync processing task is run every 15 minutes. Each definition is
processed, looking for any new or updated content since the last task was run.
In the Activity Log you'll see a message such as:

    > The Salesforce Data Sync definition "My Awesome Salesforce Data" added 123 jobs to the queue.

  As the description says, the definition was processed. Since it was last
  processed 123 new or updated records have been found and each of them has
  been turned into a job added to the queue (most often referred to as the
  "Publish Queue").

2. There are jobs in the queue and to see them easily use the [Publish Queue
Manager](https://github.com/endevver/mt-plugin-pqmanager/releases) plugin. It's
helpful to enable the Worker column (click Display Options) and filtering on
the Worker can also better show you the sync jobs ("Worker is
SalesforceDataSync::Worker"). Notice that any sync job is a very low priority
(1) so that it doesn't impact other jobs, such as for publishing content. As
with everything else in the queue, SF sync jobs get executed thanks to
`run-periodic-tasks`.

  The File Path column tell you about the sync job:
  
    * Unique key: displays the Salesforce record Name, most likely a friendly
      name that makes it clear exactly what record is syncing.
    * Coalesce value: displays the blog ID, SF data sync definition ID, the URL
      to retrieve this record, and a boolean value (0/1) to determine if this
      record should be republished after it's synced. The record URL also
      includes the record Id, which is a unique identifier in Salesforce. (Your
      field mapping should also include a filter for this value, too.)

  Each job is processed using the URL to retrieve the record from Salesforce and
  the field mapping to update an existing Entry or create a new one, as
  necessary. Note that this means any data in the Entry is overwritten by the SF
  record's data.

## Manually Syncing Data

Syncs happen automatically (every 15 minutes, assuming automatic syncing wasn't
disabled for a given definition), but there are scenarios where you might want
to manually resync data. Most specifically, if automatic sync iss disabled or if
you want to immediately see updated data.

* System Overview > Tools > Salesforce Data Sync will list all of the Salesforce
  Data Sync Definitions, and each definition tells you a little about it: when
  it was last run and if it's set to sync automatically, as well as a button to
  start a complete sync.

  Clicking the Run Complete Sync button will open a popup dialog that gives the
  opportunity to run a complete resync of the data for that definition. By
  default, a complete sync will *not* republish the blog while syncing data.
  Republishing after a complete sync has finished is a more expedient way to
  complete the process, but a checkbox allows you to enable republishing during
  the sync.

  Click the Start button to begin the sync. Records will be added to the queue
  and processed as detailed above in Monitoring Activity.

* Resync a few records by going to Manage Entries (or Manage Pages, if the sync
  definition specifies the page object type) where one of the items in the "More
  Actions..." dropdown is "Manually Resync Salesforce Data." Data is immediately
  resynced and not processed through the queue.

* Resync a single record by going to an individual Entry (or Page). In the right
  column an "Actions" widget will appear with the option to "Manually Resync
  Salesforce Data." Data is immediately resynced and not processed through the
  queue.

# License

This program is distributed under the terms of the GNU General Public License,
version 2.

# Copyright

Copyright 2015, [Endevver LLC](http://endevver.com). All rights reserved.
