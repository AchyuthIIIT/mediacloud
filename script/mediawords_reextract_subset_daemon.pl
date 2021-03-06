#!/usr/bin/env perl

#
# Enqueue MediaWords::GearmanFunction::ExtractAndVector jobs for all downloads
# in the scratch.reextract_downloads table
#

use strict;
use warnings;

BEGIN
{
    use FindBin;
    use lib "$FindBin::Bin/../lib";
}

use Modern::Perl "2013";

use Time::HiRes qw (time );
use Parallel::ForkManager;

use MediaWords::CommonLibs;
use MediaWords::GearmanFunction;
use MediaWords::GearmanFunction::ExtractAndVector;
use MediaWords::DBI::Stories;

sub main
{
    unless ( MediaWords::GearmanFunction::gearman_is_enabled() )
    {
        die "Gearman is disabled.";
    }

    my $tags_id = MediaWords::DBI::Stories::get_current_extractor_version_tags_id( MediaWords::DB::connect_to_db() );

    my $last_stories_id     = 0;
    my $story_batch_size    = 1000;
    my $gearman_queue_limit = 200;
    my $sleep_time          = 10;

    my $total_stories_enqueued     = 0;
    my $total_gearman_enqueue_time = 0;
    my $total_story_query_time     = 0;

    MediaWords::DB::disable_story_triggers();

    my $start_time = Time::HiRes::time();

    my $total_sleep_time = 0;

    my $default_db_label = MediaWords::DB::connect_settings()->{ label };

    {
	my $db         = MediaWords::DB::connect_to_db( $default_db_label );

	my $max_stories_id =  $db->query( "select max(stories_id) from scratch.reextract_stories2" )->flat()->[0];

	$last_stories_id = $max_stories_id + 1;
	say STDERR "last stories id $last_stories_id";
    }

    while ( 1 )
    {
        my $gearman_db = MediaWords::DB::connect_to_db( "gearman" );
        my $db         = MediaWords::DB::connect_to_db( $default_db_label );

        my $gearman_queued_jobs = $gearman_db->query(
            "SELECT count(*) from queue where function_name = 'MediaWords::GearmanFunction::ExtractAndVector' " )->flat()
          ->[ 0 ];

        say STDERR "Gearman queued jobs $gearman_queued_jobs";

        if ( $gearman_queued_jobs > $gearman_queue_limit )
        {
            say STDERR
"Gearman queue contains more then $gearman_queue_limit jobs ( $gearman_queued_jobs) sleeping $sleep_time seconds";
            sleep $sleep_time;
            $total_sleep_time += $sleep_time;
            next;
        }

        my $query_start_time = Time::HiRes::time();

        my $rows = $db->query(
            <<"END_SQL",
        select stories_id from scratch.reextract_stories2 where stories_id < ? order by stories_id desc limit ?;
END_SQL
            $last_stories_id, $story_batch_size
        )->hashes;

        my $query_end_time = Time::HiRes::time();

        my $stories_ids = [ map { $_->{ stories_id } } @$rows ];

        if ( scalar( @$stories_ids ) == 0 )
        {
            last;
        }

        $last_stories_id = $rows->[ -1 ]->{ stories_id };

        my $i = 0;

        #say Dumper( $stories_ids );

        my $gearman_enqueue_start_time = Time::HiRes::time();

        my $pm = new Parallel::ForkManager( 20 );

        for my $stories_id ( @{ $stories_ids } )
        {
            unless ( $pm->start )
            {
                MediaWords::GearmanFunction::ExtractAndVector->enqueue_on_gearman(
                    { stories_id => $stories_id, disable_story_triggers => 1 } );
                $pm->finish;
            }

        }

        $pm->wait_all_children;

        my $gearman_enqueue_end_time = Time::HiRes::time();

        my $enqueued_stories = scalar( @$stories_ids );
        $total_stories_enqueued += $enqueued_stories;

        my $story_query_time = $query_end_time - $query_start_time;
        $total_story_query_time += $story_query_time;

        say STDERR "last_stories_id  $last_stories_id ";
        say STDERR "total_stories_enqueued $total_stories_enqueued";
        say STDERR "story_query_time $story_query_time";

        my $gearman_enqueue_time = $gearman_enqueue_end_time - $gearman_enqueue_start_time;
        $total_gearman_enqueue_time += $gearman_enqueue_time;

        my $total_time = Time::HiRes::time() - $start_time;

        my $total_other_time = $total_time - ( $total_gearman_enqueue_time + $total_story_query_time + $total_sleep_time );

        say STDERR "gearman_enqueue_ time $gearman_enqueue_time for $enqueued_stories stories -- per story " .
          $gearman_enqueue_time / $enqueued_stories;

        say STDERR "total time $total_time for $total_stories_enqueued stories -- per story " .
          $total_time / $total_stories_enqueued;

        say STDERR
          "total gearman_enqueue_time $total_gearman_enqueue_time for $total_stories_enqueued stories -- per story " .
          $total_gearman_enqueue_time / $total_stories_enqueued;

        say STDERR "total story_query_time $total_story_query_time for $total_stories_enqueued stories -- per story " .
          $total_story_query_time / $total_stories_enqueued;

        say STDERR
          "total sleep time for long gearman queues $total_sleep_time for $total_stories_enqueued stories -- per story " .
          $total_sleep_time / $total_stories_enqueued;

        say STDERR "total time (other) $total_other_time for $total_stories_enqueued stories -- per story " .
          $total_other_time / $total_stories_enqueued;

    }

    say STDERR "all stories extracted with readability";

}

main();
