package MediaWords::CM::Dump;

# code to analyze a controversy and dump the controversy to snapshot tables and a gexf file

use strict;
use warnings;

use Data::Dumper;
use Date::Format;
use Encode;
use File::Temp;
use FileHandle;
use Getopt::Long;
use XML::Simple;
use Readonly;
use Scalar::Defer;

use MediaWords::CM::Model;
use MediaWords::DBI::Media;
use MediaWords::Util::Bitly;
use MediaWords::Util::CSV;
use MediaWords::Util::Colors;
use MediaWords::Util::Config;
use MediaWords::Util::Paths;
use MediaWords::Util::SQL;
use MediaWords::DBI::Activities;

# max and mind node sizes for gexf dump
use constant MAX_NODE_SIZE => 50;
use constant MIN_NODE_SIZE => 5;

# max map width for gexf dump
use constant MAX_MAP_WIDTH => 800;

# consistent colors for media types
my $_media_type_color_map;

# attributes to include in gexf dump
my $_media_static_gexf_attribute_types = {
    url          => 'string',
    inlink_count => 'integer',
    story_count  => 'integer',
    view_medium  => 'string'
};

# all tables that the dump process snapshots for each controversy_dump
my @_snapshot_tables = qw/
  controversy_stories controversy_links_cross_media controversy_media_codes
  stories media stories_tags_map media_tags_map tags tag_sets/;

# tablespace clause for temporary tables
my $_temporary_tablespace = lazy
{
    # if the temporary_table_tablespace config is present, set $_temporary_tablespace
    # to a tablespace clause for the tablespace, otherwise set it to ''
    my $config = MediaWords::Util::Config::get_config;

    my $tablespace = $config->{ mediawords }->{ temporary_table_tablespace };

    return $tablespace ? "tablespace $tablespace" : '';
};

# create all of the temporary dump* tables other than medium_links and story_links
sub _write_live_dump_tables
{
    my ( $db, $controversy, $cdts ) = @_;

    my $controversies_id;
    if ( $controversy )
    {
        $controversies_id = $controversy->{ controversies_id };
    }
    else
    {
        my $cd = $db->find_by_id( 'controversy_dumps', $cdts->{ controversy_dumps_id } );
        $controversies_id = $cd->{ controversies_id };
    }

    _write_temporary_dump_tables( $db, $controversies_id );
    _write_period_stories( $db, $cdts );
    _write_story_link_counts_dump( $db, $cdts, 1 );
    _write_story_links_dump( $db, $cdts, 1 );
    _write_medium_link_counts_dump( $db, $cdts, 1 );
    _write_medium_links_dump( $db, $cdts, 1 );
}

# create temporary view of all the dump_* tables that call into the cd.* tables.
# this is useful for writing queries on the cd.* tables without lots of ugly
# joins and clauses to cd and cdts.  It also provides the same set of dump_*
# tables as provided by write_story_link_counts_dump_tables, so that the same
# set of queries can run against either.
sub _create_temporary_dump_views
{
    my ( $db, $cdts ) = @_;

    for my $t ( @_snapshot_tables )
    {
        $db->query( <<END );
create temporary view dump_$t as select * from cd.$t 
    where controversy_dumps_id = $cdts->{ controversy_dumps_id }
END
    }

    for my $t ( qw(story_link_counts story_links medium_link_counts medium_links) )
    {
        $db->query( <<END )
create temporary view dump_$t as select * from cd.$t 
    where controversy_dump_time_slices_id = $cdts->{ controversy_dump_time_slices_id }
END
    }

    _add_media_type_views( $db );
}

# setup dump_* tables by either creating views for the relevant cd.*
# tables for a dump snapshot or by copying live data for live requests.
sub setup_temporary_dump_tables
{
    my ( $db, $cdts, $controversy, $live ) = @_;

    # postgres prints lots of 'NOTICE's when deleting temp tables
    $db->dbh->{ PrintWarn } = 0;

    if ( $live )
    {
        _write_live_dump_tables( $db, $controversy, $cdts );
    }
    else
    {
        _create_temporary_dump_views( $db, $cdts );
    }
}

# run $db->query( "discard temp" ) to clean up temp tables and views
sub discard_temp_tables
{
    my ( $db ) = @_;

    $db->query( "discard temp" );
}

# remove stories from dump_period_stories that don't match the $csts->{ tags_id }, if present
sub _restrict_period_stories_to_tag
{
    my ( $db, $cdts ) = @_;

    return unless ( $cdts->{ tags_id } );

    # it may be a little slower to add all the rows and then delete them, but
    # it makes the code much cleaner
    $db->query( <<END, $cdts->{ tags_id } );
delete from dump_period_stories s where not exists
        ( select 1 from stories_tags_map stm where stm.stories_id = s.stories_id and stm.tags_id = ? )
END

}

# write dump_period_stories table that holds list of all stories that should be included in the
# current period.  For an overall dump, every story should be in the current period.
# For other dumps, a story should be in the current dump if either its date is within
# the period dates or if a story that links to it has a date within the period dates.
# For this purpose, stories tagged with the 'date_invalid:undateable' tag
# are considered to have an invalid tag, so their dates cannot be used to pass
# either of the above tests.
#
# The resulting dump_period_stories should be used by all other dump queries to determine
# story membership within a give period.
sub _write_period_stories
{
    my ( $db, $cdts ) = @_;

    $db->query( "drop table if exists dump_period_stories" );

    if ( !$cdts || ( !$cdts->{ tags_id } && ( $cdts->{ period } eq 'overall' ) ) )
    {
        $db->query( <<END );
create temporary table dump_period_stories $_temporary_tablespace as select stories_id from dump_stories
END
    }
    else
    {
        $db->query( <<END );
create or replace temporary view dump_undateable_stories as
    select distinct s.stories_id
        from dump_stories s, dump_stories_tags_map stm, dump_tags t, dump_tag_sets ts
        where s.stories_id = stm.stories_id and
            stm.tags_id = t.tags_id and
            t.tag_sets_id = ts.tag_sets_id and
            ts.name = 'date_invalid' and
            t.tag = 'undateable'
END

        $db->query( <<"END", $cdts->{ start_date }, $cdts->{ end_date } );
CREATE TEMPORARY TABLE dump_period_stories $_temporary_tablespace AS

    SELECT DISTINCT dump_stories.stories_id
    FROM dump_stories
        LEFT JOIN dump_controversy_links_cross_media
            on dump_controversy_links_cross_media.ref_stories_id = dump_stories.stories_id
        LEFT JOIN dump_stories AS dump_stories_cross_media
            ON dump_controversy_links_cross_media.stories_id = dump_stories_cross_media.stories_id
    WHERE

        -- restrict the dump_period_stories creation
        -- to only stories within the cdts time frame
        (
            dump_stories.publish_date BETWEEN \$1::timestamp AND \$2::timestamp - INTERVAL '1 second' 
            AND
            dump_stories.stories_id NOT IN ( SELECT stories_id FROM dump_undateable_stories )
        ) OR (
            dump_stories_cross_media.publish_date BETWEEN \$1::timestamp AND \$2::timestamp - INTERVAL '1 second'
            AND
            dump_stories_cross_media.stories_id NOT IN ( SELECT stories_id FROM dump_undateable_stories )
        )
END

        $db->query( "drop view dump_undateable_stories" );
    }

    if ( $cdts->{ tags_id } )
    {
        _restrict_period_stories_to_tag( $db, $cdts );
    }
}

sub _create_cdts_file
{
    my ( $db, $cdts, $file_name, $file_content ) = @_;

    my $cdts_file = {
        controversy_dump_time_slices_id => $cdts->{ controversy_dump_time_slices_id },
        file_name                       => $file_name,
        file_content                    => $file_content
    };

    return $db->create( 'cdts_files', $cdts_file );
}

sub _create_cd_file
{
    my ( $db, $cd, $file_name, $file_content ) = @_;

    my $cd_file = {
        controversy_dumps_id => $cd->{ controversy_dumps_id },
        file_name            => $file_name,
        file_content         => $file_content
    };

    return $db->create( 'cd_files', $cd_file );
}

# convenience function to update a field in the cdts table
sub update_cdts
{
    my ( $db, $cdts, $field, $val ) = @_;

    $db->update_by_id( 'controversy_dump_time_slices', $cdts->{ controversy_dump_time_slices_id }, { $field => $val } );
}

sub _get_story_links_csv
{
    my ( $db, $cdts ) = @_;

    my $csv = MediaWords::Util::CSV::get_query_as_csv( $db, <<END );
select distinct sl.source_stories_id source_stories_id, ss.title source_title, ss.url source_url, 
        sm.name source_media_name, sm.url source_media_url, sm.media_id source_media_id,
		sl.ref_stories_id ref_stories_id, rs.title ref_title, rs.url ref_url, rm.name ref_media_name, rm.url ref_media_url, 
		rm.media_id ref_media_id
	from dump_story_links sl, cd.live_stories ss, media sm, cd.live_stories rs, media rm
	where sl.source_stories_id = ss.stories_id and 
	    ss.media_id = sm.media_id and 
	    sl.ref_stories_id = rs.stories_id and 
	    rs.media_id = rm.media_id
END

    return $csv;
}

sub _write_story_links_csv
{
    my ( $db, $cdts ) = @_;

    my $csv = _get_story_links_csv( $db, $cdts );

    _create_cdts_file( $db, $cdts, 'story_links.csv', $csv );
}

sub _write_story_links_dump
{
    my ( $db, $cdts, $is_model ) = @_;

    $db->query( "drop table if exists dump_story_links" );

    $db->query( <<END );
create temporary table dump_story_links $_temporary_tablespace as
    select distinct cl.stories_id source_stories_id, cl.ref_stories_id
	    from dump_controversy_links_cross_media cl, dump_period_stories sps, dump_period_stories rps
    	where cl.stories_id = sps.stories_id and
    	    cl.ref_stories_id = rps.stories_id
END

    # re-enable above to prevent post-dated links
    #          ss.publish_date > rs.publish_date - interval '1 day' and

    if ( !$is_model )
    {
        _create_cdts_snapshot( $db, $cdts, 'story_links' );
        _write_story_links_csv( $db, $cdts );
    }
}

sub _get_stories_csv
{
    my ( $db, $cdts ) = @_;

    my $controversy = $db->query( <<END, $cdts->{ controversy_dumps_id } );
select * from controversies c, controversy_dumps cd
    where c.controversies_id = cd.controversies_id and cd.controversy_dumps_id = ?
END

    my $tagset_name = "Controversy $cdts->{ controversy_dump }->{ controversy }->{ name }";

    my $tags = $db->query( <<END, $tagset_name )->hashes;
select * from dump_tags t, dump_tag_sets ts 
    where t.tag_sets_id = ts.tag_sets_id and ts.name = ? and t.tag <> 'all'
END

    my $tag_clauses = [];
    for my $tag ( @{ $tags } )
    {
        my $label = "tagged_" . $tag->{ tag };

        push(
            @{ $tag_clauses },
            "exists ( select 1 from dump_stories_tags_map stm " .
              "  where s.stories_id = stm.stories_id and stm.tags_id = $tag->{ tags_id } ) $label "
        );
    }

    my $tag_clause_list = join( ',', @{ $tag_clauses } );
    $tag_clause_list = ", $tag_clause_list" if ( $tag_clause_list );

    my $csv = MediaWords::Util::CSV::get_query_as_csv( $db, <<END );
select distinct s.stories_id, s.title, s.url,
        case when ( stm.tags_id is null ) then s.publish_date::text else 'undateable' end as publish_date,
        m.name media_name, m.url media_url, m.media_id,
        slc.inlink_count, slc.outlink_count, slc.bitly_click_count, slc.bitly_referrer_count
        $tag_clause_list
	from dump_stories s
	    join dump_media m on ( s.media_id = m.media_id )
	    join dump_story_link_counts slc on ( s.stories_id = slc.stories_id ) 
	    left join (
	        stories_tags_map stm
                join tags t on ( stm.tags_id = t.tags_id  and t.tag = 'undateable' )
                join tag_sets ts on ( t.tag_sets_id = ts.tag_sets_id and ts.name = 'date_invalid' ) )
            on ( stm.stories_id = s.stories_id )
	order by slc.inlink_count
END

    return $csv;
}

sub _write_stories_csv
{
    my ( $db, $cdts ) = @_;

    my $csv = _get_stories_csv( $db, $cdts );

    _create_cdts_file( $db, $cdts, 'stories.csv', $csv );
}

sub _write_story_link_counts_dump
{
    my ( $db, $cdts, $is_model ) = @_;

    $db->query( "drop table if exists dump_story_link_counts" );

    $db->query( <<END );
create temporary table dump_story_link_counts $_temporary_tablespace as
    select distinct ps.stories_id, 
            coalesce( ilc.inlink_count, 0 ) inlink_count, 
            coalesce( olc.outlink_count, 0 ) outlink_count,
            bsc.click_count as bitly_click_count,
            bsr.referrer_count as bitly_referrer_count
        from dump_period_stories ps
            left join 
                ( select cl.ref_stories_id,
                         count( distinct cl.stories_id ) inlink_count 
                  from dump_controversy_links_cross_media cl,
                       dump_period_stories ps
                  where cl.stories_id = ps.stories_id
                  group by cl.ref_stories_id
                ) ilc on ( ps.stories_id = ilc.ref_stories_id )
            left join 
                ( select cl.stories_id,
                         count( distinct cl.ref_stories_id ) outlink_count 
                  from dump_controversy_links_cross_media cl,
                       dump_period_stories ps
                  where cl.ref_stories_id = ps.stories_id
                  group by cl.stories_id
                ) olc on ( ps.stories_id = olc.stories_id )
            left join
                ( select bitly_story_clicks.stories_id,
                         sum( bitly_story_clicks.click_count ) as click_count
                  from bitly_story_clicks,
                       dump_period_stories ps
                  where bitly_story_clicks.stories_id = ps.stories_id
                  group by bitly_story_clicks.stories_id
                ) as bsc on ( ps.stories_id = bsc.stories_id )
            left join
                ( select bitly_story_referrers.stories_id,
                         sum( bitly_story_referrers.referrer_count ) as referrer_count
                  from bitly_story_referrers,
                       dump_period_stories ps
                  where bitly_story_referrers.stories_id = ps.stories_id
                  group by bitly_story_referrers.stories_id
                ) as bsr on ( ps.stories_id = bsr.stories_id )
END

    if ( !$is_model )
    {
        _create_cdts_snapshot( $db, $cdts, 'story_link_counts' );
        _write_stories_csv( $db, $cdts );
    }
}

sub _add_tags_to_dump_media
{
    my ( $db, $cdts, $media ) = @_;

    my $tagset_name = "controversy_$cdts->{ controversy_dump }->{ controversy }->{ name }";

    my $tags = $db->query( <<END, $tagset_name )->hashes;
select * from dump_tags t, dump_tag_sets ts
  where t.tag_sets_id = ts.tag_sets_id and ts.name = ? and t.tag <> 'all'
END

    my $tag_fields = [];
    for my $tag ( @{ $tags } )
    {
        my $label = "tagged_" . $tag->{ tag };

        push( @{ $tag_fields }, $label );

        my $media_tags = $db->query( <<END, $tag->{ tags_id } )->hashes;
select s.media_id, stm.* 
    from dump_stories s, dump_story_link_counts slc, dump_stories_tags_map stm 
    where s.stories_id = slc.stories_id and s.stories_id = stm.stories_id and stm.tags_id = ?
END
        my $media_tags_map = {};
        map { $media_tags_map->{ $_->{ media_id } } += 1 } @{ $media_tags };

        map { $_->{ $label } = $media_tags_map->{ $_->{ media_id } } || 0 } @{ $media };
    }

    return $tag_fields;
}

sub _add_codes_to_dump_media
{
    my ( $db, $cdts, $media ) = @_;

    my $code_types = $db->query( <<END )->flat;
select distinct code_type from dump_controversy_media_codes
END

    my $code_fields = [];
    for my $code_type ( @{ $code_types } )
    {
        my $label = "code_" . $code_type;

        push( @{ $code_fields }, $label );

        my $media_codes = $db->query( <<END, $code_type )->hashes;
select * from dump_controversy_media_codes where code_type = ?
END
        my $media_codes_map = {};
        map { $media_codes_map->{ $_->{ media_id } } = $_->{ code } } @{ $media_codes };

        map { $_->{ $label } = $media_codes_map->{ $_->{ media_id } } || 'null' } @{ $media };
    }

    return $code_fields;
}

sub _get_media_csv
{
    my ( $db, $cdts ) = @_;

    my $res = $db->query( <<END );
select m.media_id, m.name, m.url, mlc.inlink_count, mlc.outlink_count, 
        mlc.story_count, mlc.bitly_click_count, mlc.bitly_referrer_count
    from dump_media m, dump_medium_link_counts mlc
    where m.media_id = mlc.media_id
    order by mlc.inlink_count desc;
END

    my $fields = $res->columns;
    my $media  = $res->hashes;

    my $code_fields = _add_codes_to_dump_media( $db, $cdts, $media );
    my $tag_fields = _add_tags_to_dump_media( $db, $cdts, $media );

    push( @{ $fields }, @{ $code_fields } );
    push( @{ $fields }, @{ $tag_fields } );

    my $csv = MediaWords::Util::CSV::get_hashes_as_encoded_csv( $media, $fields );

    return $csv;
}

sub _write_media_csv
{
    my ( $db, $cdts ) = @_;

    my $csv = _get_media_csv( $db, $cdts );

    _create_cdts_file( $db, $cdts, 'media.csv', $csv );
}

sub _write_medium_link_counts_dump
{
    my ( $db, $cdts, $is_model ) = @_;

    $db->query( "drop table if exists dump_medium_link_counts" );

    $db->query( <<END );
create temporary table dump_medium_link_counts $_temporary_tablespace as   
    select m.media_id,
           sum( slc.inlink_count) inlink_count,
           sum( slc.outlink_count) outlink_count,
           count(*) story_count,
           sum( slc.bitly_click_count ) bitly_click_count,
           sum( slc.bitly_referrer_count ) bitly_referrer_count
        from dump_media m, dump_stories s, dump_story_link_counts slc 
        where m.media_id = s.media_id and s.stories_id = slc.stories_id
        group by m.media_id
END

    if ( !$is_model )
    {
        _create_cdts_snapshot( $db, $cdts, 'medium_link_counts' );
        _write_media_csv( $db, $cdts );
    }
}

sub _get_medium_links_csv
{
    my ( $db, $cdts ) = @_;

    my $csv = MediaWords::Util::CSV::get_query_as_csv( $db, <<END );
select ml.source_media_id, sm.name source_name, sm.url source_url,
        ml.ref_media_id, rm.name ref_name, rm.url ref_url, ml.link_count 
    from dump_medium_links ml, media sm, media rm
    where ml.source_media_id = sm.media_id and ml.ref_media_id = rm.media_id
END

    return $csv;
}

sub _write_medium_links_csv
{
    my ( $db, $cdts ) = @_;

    my $csv = _get_medium_links_csv( $db, $cdts );

    _create_cdts_file( $db, $cdts, 'medium_links.csv', $csv );
}

sub _write_medium_links_dump
{
    my ( $db, $cdts, $is_model ) = @_;

    $db->query( "drop table if exists dump_medium_links" );

    $db->query( <<END );
create temporary table dump_medium_links $_temporary_tablespace as
    select s.media_id source_media_id, r.media_id ref_media_id, count(*) link_count
        from dump_story_links sl, dump_stories s, dump_stories r
        where sl.source_stories_id = s.stories_id and sl.ref_stories_id = r.stories_id
        group by s.media_id, r.media_id
END

    if ( !$is_model )
    {
        _create_cdts_snapshot( $db, $cdts, 'medium_links' );
        _write_medium_links_csv( $db, $cdts );
    }
}

sub _write_date_counts_csv
{
    my ( $db, $cd, $period ) = @_;

    my $csv = MediaWords::Util::CSV::get_query_as_csv( $db, <<END );
select dc.publish_date, t.tag, t.tags_id, dc.story_count
    from dump_${ period }_date_counts dc, tags t
    where dc.tags_id = t.tags_id
    order by t.tag, dc.publish_date
END

    _create_cd_file( $db, $cd, "${ period }_counts.csv", $csv );
}

sub _write_date_counts_dump
{
    my ( $db, $cd, $period ) = @_;

    die( "unknown period '$period'" ) unless ( grep { $period eq $_ } qw(daily weekly) );
    my $date_trunc = ( $period eq 'daily' ) ? 'day' : 'week';

    $db->query( <<END, $date_trunc, $date_trunc );
create temporary table dump_${ period }_date_counts $_temporary_tablespace as
    select date_trunc( ?, s.publish_date ) publish_date, t.tags_id, count(*) story_count
        from dump_stories s, dump_stories_tags_map stm, dump_tags t
        where s.stories_id = stm.stories_id and
            stm.tags_id = t.tags_id
        group by date_trunc( ?, s.publish_date ), t.tags_id
END

    _create_cd_snapshot( $db, $cd, "${ period }_date_counts" );

    _write_date_counts_csv( $db, $cd, $period );
}

sub _add_tags_to_gexf_attribute_types
{
    my ( $db, $cdts ) = @_;

    my $tagset_name = "controversy_$cdts->{ controversy_dump }->{ controversy }->{ name }";

    my $tags = $db->query( <<END, $tagset_name )->hashes;
select * from dump_tags t, dump_tag_sets ts where t.tag_sets_id = ts.tag_sets_id and ts.name = ? and t.tag <> 'all'
END

    map { $_media_static_gexf_attribute_types->{ "tagged_" . $_->{ tag } } = 'integer' } @{ $tags };
}

sub _add_codes_to_gexf_attribute_types
{
    my ( $db, $cdts ) = @_;

    my $code_types = $db->query( "select distinct code_type from dump_controversy_media_codes" )->flat;

    map { $_media_static_gexf_attribute_types->{ "code_" . $_ } = 'string' } @{ $code_types };
}

sub _get_link_weighted_edges
{
    my ( $db ) = @_;

    my $media_links = $db->query( "select * from dump_medium_links" )->hashes;

    my $edges = [];
    my $k     = 0;
    for my $media_link ( @{ $media_links } )
    {
        my $edge = {
            id     => $k++,
            source => $media_link->{ source_media_id },
            target => $media_link->{ ref_media_id },
            weight => $media_link->{ inlink_count }
        };

        push( @{ $edges }, $edge );
    }

    return $edges;
}

sub _get_weighted_edges
{
    my ( $db ) = @_;

    return _get_link_weighted_edges( $db );
}

sub _get_media_type_color
{
    my ( $db, $cdts, $media_type ) = @_;

    $media_type ||= 'none';

    return $_media_type_color_map->{ $media_type } if ( $_media_type_color_map );

    my $all_media_types = $db->query( <<END )->flat;
select distinct media_type from dump_media_with_types
END

    my $num_colors = scalar( @{ $all_media_types } ) + 1;

    my $hex_colors = MediaWords::Util::Colors::get_colors( $num_colors );
    my $color_list = [ map { MediaWords::Util::Colors::get_color_hash_from_hex( $_ ) } @{ $hex_colors } ];

    $_media_type_color_map = {};
    for my $media_type ( @{ $all_media_types } )
    {
        $_media_type_color_map->{ $media_type } = pop( @{ $color_list } );
    }

    $_media_type_color_map->{ none } = pop( @{ $color_list } );

    return $_media_type_color_map->{ $media_type };
}

# gephi removes the weights from the media links.  add them back in.
sub _add_weights_to_gexf_edges
{
    my ( $db, $gexf ) = @_;

    my $edges = $gexf->{ graph }->[ 0 ]->{ edges }->[ 0 ]->{ edge };

    my $medium_links = $db->query( "select * from dump_medium_links" )->hashes;

    my $edge_weight_lookup = {};
    for my $m ( @{ $medium_links } )
    {
        $edge_weight_lookup->{ $m->{ source_media_id } }->{ $m->{ ref_media_id } } = $m->{ link_count };
    }

    for my $edge ( @{ $edges } )
    {
        $edge->{ weight } = $edge_weight_lookup->{ $edge->{ source } }->{ $edge->{ target } };
    }
}

# scale the size of the map described in the gexf file to 800 x 700.
# gephi can return really large maps that make the absolute node size relatively tiny.
# we need to scale the map to get consistent, reasonable node sizes across all maps
sub _scale_gexf_nodes
{
    my ( $db, $gexf ) = @_;

    # print Dumper( $gexf );

    my $nodes = $gexf->{ graph }->[ 0 ]->{ nodes }->[ 0 ]->{ node };

    # we assume that the gephi maps are symmetrical and so only check the
    my $max_x = 0;
    for my $node ( @{ $nodes } )
    {
        my $p = $node->{ 'viz:position' }->[ 0 ];
        $max_x = $p->{ x } if ( !defined( $max_x ) || ( $p->{ x } > $max_x ) );
    }

    my $map_width = $max_x * 2;

    if ( $map_width > MAX_MAP_WIDTH )
    {
        my $scale = MAX_MAP_WIDTH / $map_width;

        for my $node ( @{ $nodes } )
        {
            my $p = $node->{ 'viz:position' }->[ 0 ];
            $p->{ x } *= $scale;
            $p->{ y } *= $scale;
        }
    }
}

# post process gexf file.  gephi mucks up the gexf file by making it too big and
# removing the weights from the gexf export.  I can't figure out how to get the gephi toolkit
# to fix these things, so I just fix them in perl
sub _post_process_gexf
{
    my ( $db, $gexf_file ) = @_;

    my $gexf = XML::Simple::XMLin( $gexf_file, ForceArray => 1, ForceContent => 1, KeyAttr => [] );

    _add_weights_to_gexf_edges( $db, $gexf );

    _scale_gexf_nodes( $db, $gexf );

    open( FILE, ">$gexf_file" ) || die( "Unable to open file '$gexf_file': $!" );

    print FILE encode( 'utf8', XML::Simple::XMLout( $gexf, XMLDecl => 1, RootName => 'gexf' ) );

    close FILE;

}

# call java program to lay out graph.  the java program accepts a gexf file as input and
# outputs a gexf file with the lay out included
sub _layout_gexf
{
    my ( $db, $cdts, $nolayout_gexf ) = @_;

    print STDERR "generating gephi layout ...\n";

    my $tmp_dir = File::Temp::tempdir( "dump_layout_$cdts->{ controversy_dump_time_slices_id }_XXXX" );

    my $nolayout_path = "$tmp_dir/nolayout.gexf";
    my $layout_path   = "$tmp_dir/layout.gexf";

    my $fh = FileHandle->new( ">$nolayout_path" ) || die( "Unable to open file '$nolayout_path': $!" );
    $fh->print( encode( 'utf8', $nolayout_gexf ) );
    $fh->close();

    Readonly my $PATH_TO_GEPHILAYOUT_DIR     => MediaWords::Util::Paths::mc_root_path() . '/java/GephiLayout/';
    Readonly my $PATH_TO_GEPHILAYOUT_JAR     => "$PATH_TO_GEPHILAYOUT_DIR/build/jar/GephiLayout.jar";
    Readonly my $PATH_TO_GEPHILAYOUT_TOOLKIT => "$PATH_TO_GEPHILAYOUT_DIR/lib/gephi-toolkit.jar";
    unless ( -f $PATH_TO_GEPHILAYOUT_JAR )
    {
        die "GephiLayout.jar does not exist at path: $PATH_TO_GEPHILAYOUT_JAR";
    }
    unless ( -f $PATH_TO_GEPHILAYOUT_TOOLKIT )
    {
        die "gephi-toolkit.jar does not exist at path: $PATH_TO_GEPHILAYOUT_TOOLKIT";
    }

    my $cmd = "";
    $cmd .= "java -cp $PATH_TO_GEPHILAYOUT_JAR:$PATH_TO_GEPHILAYOUT_TOOLKIT";
    $cmd .= " ";
    $cmd .= "edu.law.harvard.cyber.mediacloud.layout.GephiLayout";
    $cmd .= " ";
    $cmd .= "$nolayout_path $layout_path";

    # print STDERR "$cmd\n";
    my $exit_code = system( $cmd );
    unless ( $exit_code == 0 )
    {
        die "Command '$cmd' failed with exit code $exit_code.";
    }

    _post_process_gexf( $db, $layout_path );

    $fh = FileHandle->new( $layout_path ) || die( "Unable to open file '$layout_path': $!" );

    my $layout_gexf;
    while ( my $line = $fh->getline )
    {
        $layout_gexf .= decode( 'utf8', $line );
    }

    $fh->close;

    unlink( $layout_path, $nolayout_path );
    rmdir( $tmp_dir );

    return $layout_gexf;
}

# scale the nodes such that the biggest node size is MAX_NODE_SIZE and the smallest is MIN_NODE_SIZE
sub _scale_node_sizes
{
    my ( $nodes ) = @_;

    map { $_->{ 'viz:size' }->{ value } += 1 } @{ $nodes };

    my $max_size = 1;
    map { my $s = $_->{ 'viz:size' }->{ value }; $max_size = $s if ( $max_size < $s ); } @{ $nodes };

    my $scale = MAX_NODE_SIZE / $max_size;
    if ( $scale > 1 )
    {
        $scale = 0.5 + ( $scale / 2 );
    }

    # my $scale = ( $max_size > ( MAX_NODE_SIZE / MIN_NODE_SIZE ) ) ? ( MAX_NODE_SIZE / $max_size ) : 1;

    for my $node ( @{ $nodes } )
    {
        my $s = $node->{ 'viz:size' }->{ value };

        $s = int( $scale * $s );

        $s = MIN_NODE_SIZE if ( $s < MIN_NODE_SIZE );

        $node->{ 'viz:size' }->{ value } = $s;

        # say STDERR "viz:size $s";
    }
}

# write gexf dump of nodes
sub _write_gexf_dump
{
    my ( $db, $cdts ) = @_;

    _add_tags_to_gexf_attribute_types( $db, $cdts );
    _add_codes_to_gexf_attribute_types( $db, $cdts );

    my $media = $db->query( <<END )->hashes;
select * from dump_media_with_types m, dump_medium_link_counts mlc where m.media_id = mlc.media_id
END

    _add_codes_to_dump_media( $db, $cdts, $media );
    _add_tags_to_dump_media( $db, $cdts, $media );

    my $gexf = {
        'xmlns'              => "http://www.gexf.net/1.2draft",
        'xmlns:xsi'          => "http://www.w3.org/2001/XMLSchema-instance",
        'xmlns:viz'          => "http://www.gexf.net/1.1draft/viz",
        'xsi:schemaLocation' => "http://www.gexf.net/1.2draft http://www.gexf.net/1.2draft/gexf.xsd",
        'version'            => "1.2"
    };

    my $meta = { 'lastmodifieddate' => Date::Format::time2str( '%Y-%m-%d', time ) };
    push( @{ $gexf->{ meta } }, $meta );

    push( @{ $meta->{ creator } }, 'Berkman Center' );

    my $controversy = $cdts->{ controversy_dump }->{ controversy };
    push( @{ $meta->{ description } }, "Media discussions of $controversy->{ name }" );

    my $graph = {
        'mode'            => "dynamic",
        'defaultedgetype' => "directed",
        'timeformat'      => "date"
    };
    push( @{ $gexf->{ graph } }, $graph );

    my $attributes = { class => 'node', mode => 'static' };
    push( @{ $graph->{ attributes } }, $attributes );

    my $i = 0;
    while ( my ( $name, $type ) = each( %{ $_media_static_gexf_attribute_types } ) )
    {
        push( @{ $attributes->{ attribute } }, { id => $i++, title => $name, type => $type } );
    }

    my $edges = _get_weighted_edges( $db );
    $graph->{ edges }->{ edge } = $edges;

    my $edge_lookup = {};
    for my $edge ( @{ $edges } )
    {
        $edge_lookup->{ $edge->{ source } } ||= 0;
        $edge_lookup->{ $edge->{ target } } += $edge->{ weight } || 0;
    }

    my $total_link_count = 1;
    map { $total_link_count += $_->{ inlink_count } } @{ $media };

    for my $medium ( @{ $media } )
    {
        next unless ( $medium->{ inlink_count } || $medium->{ outlink_count } );

        my $node = {
            id    => $medium->{ media_id },
            label => $medium->{ name },
        };

        $medium->{ view_medium } =
          "[_mc_base_url_]/admin/cm/medium/$medium->{ media_id }?cdts=$cdts->{ controversy_dump_time_slices_id }";

        my $j = 0;
        while ( my ( $name, $type ) = each( %{ $_media_static_gexf_attribute_types } ) )
        {
            push( @{ $node->{ attvalues }->{ attvalue } }, { for => $j++, value => $medium->{ $name } } );
        }

        # for my $story ( @{ $medium->{ stories } } )
        # {
        #     my $story_date = substr( $story->{ publish_date }, 0, 10 );
        #     push( @{ $node->{ spells }->{ spell } }, { start => $story_date, end => $story_date } );
        # }

        $node->{ 'viz:color' } = [ _get_media_type_color( $db, $cdts, $medium->{ media_type } ) ];
        $node->{ 'viz:size' } = { value => $medium->{ inlink_count } + 1 };

        push( @{ $graph->{ nodes }->{ node } }, $node );
    }

    _scale_node_sizes( $graph->{ nodes }->{ node } );

    my $nolayout_gexf = XML::Simple::XMLout( $gexf, XMLDecl => 1, RootName => 'gexf' );

    my $layout_gexf = _layout_gexf( $db, $cdts, $nolayout_gexf );

    _create_cdts_file( $db, $cdts, 'media.gexf', encode( 'utf8', $layout_gexf ) );
}

sub _create_controversy_dump_time_slice($$$$$$)
{
    my ( $db, $cd, $start_date, $end_date, $period, $tag ) = @_;

    my $cdts = {
        controversy_dumps_id => $cd->{ controversy_dumps_id },
        start_date           => $start_date,
        end_date             => $end_date,
        period               => $period,
        story_count          => 0,
        story_link_count     => 0,
        medium_count         => 0,
        medium_link_count    => 0,
        tags_id              => $tag ? $tag->{ tags_id } : undef
    };

    $cdts = $db->create( 'controversy_dump_time_slices', $cdts );

    $cdts->{ controversy_dump } = $cd;

    return $cdts;
}

# generate data for the story_links, story_link_counts, media_links, media_link_counts tables
# based on the data in the temporary dump_* tables
sub generate_cdts_data ($$;$)
{
    my ( $db, $cdts, $is_model ) = @_;

    _write_period_stories( $db, $cdts );

    _write_story_link_counts_dump( $db, $cdts, $is_model );
    _write_story_links_dump( $db, $cdts, $is_model );
    _write_medium_link_counts_dump( $db, $cdts, $is_model );
    _write_medium_links_dump( $db, $cdts, $is_model );
}

# update *_count fields in cdts.  save to db unless $live is specified.
sub update_cdts_counts ($$;$)
{
    my ( $db, $cdts, $live ) = @_;

    ( $cdts->{ story_count } ) = $db->query( "select count(*) from dump_story_link_counts" )->flat;

    ( $cdts->{ story_link_count } ) = $db->query( "select count(*) from dump_story_links" )->flat;

    ( $cdts->{ medium_count } ) = $db->query( "select count(*) from dump_medium_link_counts" )->flat;

    ( $cdts->{ medium_link_count } ) = $db->query( "select count(*) from dump_medium_links" )->flat;

    return if ( $live );

    for my $field ( qw(story_count story_link_count medium_count medium_link_count) )
    {
        update_cdts( $db, $cdts, $field, $cdts->{ $field } );
    }
}

# generate the dump time slices for the given period, dates, and tag
sub _generate_cdts($$$$$$)
{
    my ( $db, $cd, $start_date, $end_date, $period, $tag ) = @_;

    my $cdts = _create_controversy_dump_time_slice( $db, $cd, $start_date, $end_date, $period, $tag );

    my $dump_label = "${ period }: ${ start_date } - ${ end_date } " . ( $tag ? "[ $tag->{ tag } ]" : "" );
    print "generating $dump_label ...\n";

    my $all_models_top_media = MediaWords::CM::Model::get_all_models_top_media( $db, $cdts );

    print "\ngenerating dump data ...\n";
    generate_cdts_data( $db, $cdts );

    update_cdts_counts( $db, $cdts );

    if ( $all_models_top_media )
    {
        MediaWords::CM::Model::print_model_matches( $db, $cdts, $all_models_top_media );
        MediaWords::CM::Model::update_model_correlation( $db, $cdts, $all_models_top_media );
    }

    # my $confidence = get_model_confidence( $db, $cdts, $all_models_top_media );
    # print "confidence: $confidence\n";

    _write_gexf_dump( $db, $cdts );
}

# generate dumps for the periods in controversy_dates
sub _generate_custom_period_dump($$$)
{
    my ( $db, $cd, $tag ) = @_;

    my $controversy_dates = $db->query( <<END, $cd->{ controversies_id } )->hashes;
select * from controversy_dates where controversies_id = ? order by start_date, end_date
END

    for my $controversy_date ( @{ $controversy_dates } )
    {
        my $start_date = $controversy_date->{ start_date };
        my $end_date   = $controversy_date->{ end_date };
        _generate_cdts( $db, $cd, $start_date, $end_date, 'custom', $tag );
    }
}

# generate dump for the given period (overall, monthly, weekly, or custom) and the given tag
sub _generate_period_dump($$$$)
{
    my ( $db, $cd, $period, $tag ) = @_;

    my $start_date = $cd->{ start_date };
    my $end_date   = $cd->{ end_date };

    if ( $period eq 'overall' )
    {
        _generate_cdts( $db, $cd, $start_date, $end_date, $period, $tag );
    }
    elsif ( $period eq 'weekly' )
    {
        my $w_start_date = MediaWords::Util::SQL::truncate_to_monday( $start_date );
        while ( $w_start_date lt $end_date )
        {
            my $w_end_date = MediaWords::Util::SQL::increment_day( $w_start_date, 7 );

            _generate_cdts( $db, $cd, $w_start_date, $w_end_date, $period, $tag );

            $w_start_date = $w_end_date;
        }
    }
    elsif ( $period eq 'monthly' )
    {
        my $m_start_date = MediaWords::Util::SQL::truncate_to_start_of_month( $start_date );
        while ( $m_start_date lt $end_date )
        {
            my $m_end_date = MediaWords::Util::SQL::increment_day( $m_start_date, 32 );
            $m_end_date = MediaWords::Util::SQL::truncate_to_start_of_month( $m_end_date );

            _generate_cdts( $db, $cd, $m_start_date, $m_end_date, $period, $tag );

            $m_start_date = $m_end_date;
        }
    }
    elsif ( $period eq 'custom' )
    {
        _generate_custom_period_dump( $db, $cd, $tag );
    }
    else
    {
        die( "Unknown period '$period'" );
    }
}

# get default start and end dates from the query associated with the query_stories_search associated with the controversy
sub _get_default_dates
{
    my ( $db, $controversy ) = @_;

    my ( $start_date, $end_date ) = $db->query( <<END, $controversy->{ controversies_id } )->flat;
select min( cd.start_date ), max( cd.end_date ) from controversy_dates cd where cd.controversies_id = ?
END

    die( "Unable to find default dates" ) unless ( $start_date && $end_date );

    return ( $start_date, $end_date );

}

# create temporary table copies of temporary tables so that we can copy
# the data back into the main temporary tables after tweaking the main temporary tables
sub copy_temporary_tables
{
    my ( $db ) = @_;

    for my $snapshot_table ( @_snapshot_tables )
    {
        my $dump_table = "dump_${ snapshot_table }";
        my $copy_table = "_copy_${ dump_table }";

        $db->query( "drop table if exists $copy_table" );
        $db->query( "create temporary table $copy_table $_temporary_tablespace as select * from $dump_table" );
    }
}

# restore original, copied data back into dump tables
sub restore_temporary_tables
{
    my ( $db ) = @_;

    for my $snapshot_table ( @_snapshot_tables )
    {
        my $dump_table = "dump_${ snapshot_table }";
        my $copy_table = "_copy_${ dump_table }";

        $db->query( "drop table if exists $dump_table cascade" );
        $db->query( "create temporary table $dump_table $_temporary_tablespace as select * from $copy_table" );
    }

    _add_media_type_views( $db );
}

# create a snapshot for the given table from the temporary dump_* table,
# making sure to specify all the fields in the copy so that we don't have to
# assume column position is the same in the original and snapshot tables.
# use the $key from $obj as an additional field in the snapshot table.
sub _create_snapshot
{
    my ( $db, $obj, $key, $table ) = @_;

    say STDERR "snapshot $table...";

    my $column_names = [ $db->query( <<END, $table, $key )->flat ];
select column_name from information_schema.columns 
    where table_name = ? and table_schema = 'cd' and
        column_name not in ( ? )
    order by ordinal_position asc
END

    die( "Field names can only have letters and underscores" ) if ( grep { /[^a-z_]/i } @{ $column_names } );
    die( "Table name can only have letters and underscores" ) if ( $table =~ /[^a-z_]/i );

    my $column_list = join( ",", @{ $column_names } );

    $db->query( <<END, $obj->{ $key } );
insert into cd.${ table } ( $column_list, $key ) select $column_list, ? from dump_${ table }
END

}

# create a snapshot of a table for a controversy_dump_time_slice
sub _create_cdts_snapshot
{
    my ( $db, $cdts, $table ) = @_;

    _create_snapshot( $db, $cdts, 'controversy_dump_time_slices_id', $table );
}

# create a snapshot of a table for a controversy_dump
sub _create_cd_snapshot
{
    my ( $db, $cd, $table ) = @_;

    _create_snapshot( $db, $cd, 'controversy_dumps_id', $table );
}

# generate temporary dump_* tables for the specified controversy_dump for each of the snapshot_tables.
# these are the tables that apply to the whole controversy_dump.
sub _write_temporary_dump_tables
{
    my ( $db, $controversies_id ) = @_;

    $db->query( <<END, $controversies_id );
create temporary table dump_controversy_stories $_temporary_tablespace as 
    select cs.*
        from controversy_stories cs
        where cs.controversies_id = ?
END

    $db->query( <<END, $controversies_id );
create temporary table dump_controversy_media_codes $_temporary_tablespace as 
    select cmc.*
        from controversy_media_codes cmc
        where cmc.controversies_id = ?
END

    $db->query( <<END, $controversies_id );
create temporary table dump_stories $_temporary_tablespace as
    select s.stories_id, s.media_id, s.url, s.guid, s.title, s.publish_date, s.collect_date, s.full_text_rss, s.language
        from cd.live_stories s
            join dump_controversy_stories dcs on ( s.stories_id = dcs.stories_id and s.controversies_id = ? )
END

    $db->query( <<END );
create temporary table dump_media $_temporary_tablespace as
    select m.* from media m
        where m.media_id in ( select media_id from dump_stories )
END

    $db->query( <<END, $controversies_id );
create temporary table dump_controversy_links_cross_media $_temporary_tablespace as
    select s.stories_id, r.stories_id ref_stories_id, cl.url, cs.controversies_id, cl.controversy_links_id
        from controversy_links cl
            join dump_controversy_stories cs on ( cs.stories_id = cl.ref_stories_id )
            join dump_stories s on ( cl.stories_id = s.stories_id )
            join dump_media sm on ( s.media_id = sm.media_id )
            join dump_stories r on ( cl.ref_stories_id = r.stories_id )
            join dump_media rm on ( r.media_id= rm.media_id )
        where cl.controversies_id = ? and r.media_id <> s.media_id
END

    $db->query( <<END );
create temporary table dump_stories_tags_map $_temporary_tablespace as
    select stm.*
    from stories_tags_map stm, dump_stories ds
    where stm.stories_id = ds.stories_id
END

    $db->query( <<END );
create temporary table dump_media_tags_map $_temporary_tablespace as
    select mtm.*
    from media_tags_map mtm, dump_media dm
    where mtm.media_id = dm.media_id
END

    $db->query( <<END );
create temporary table dump_tags $_temporary_tablespace as
    select distinct t.* from tags t where t.tags_id in
        ( select distinct a.tags_id
            from tags a
                join dump_media_tags_map amtm on ( a.tags_id = amtm.tags_id )
        
          union

          select distinct b.tags_id
            from tags b
                join dump_stories_tags_map bstm on ( b.tags_id = bstm.tags_id )
        )
     
END

    $db->query( <<END );
create temporary table dump_tag_sets $_temporary_tablespace as
    select ts.*
    from tag_sets ts
    where ts.tag_sets_id in ( select tag_sets_id from dump_tags )
END

    _add_media_type_views( $db );

}

sub _add_media_type_views
{
    my ( $db ) = @_;

    $db->query( <<END );
create or replace view dump_media_with_types as
    with controversies_id as (
        select controversies_id from dump_controversy_stories limit 1
    )

    select 
            m.*, 
            case 
                when ( ct.label <> 'Not Typed' )
                    then ct.label
                when ( ut.label is not null )
                    then ut.label
                else
                    'Not Typed'
                end as media_type
        from 
            dump_media m
            left join (
                dump_tags ut
                join dump_tag_sets uts on ( ut.tag_sets_id = uts.tag_sets_id and uts.name = 'media_type' )
                join dump_media_tags_map umtm on ( umtm.tags_id = ut.tags_id )
            ) on ( m.media_id = umtm.media_id )
            left join (
                dump_tags ct
                join dump_media_tags_map cmtm on ( cmtm.tags_id = ct.tags_id )
                join controversies c on ( c.media_type_tag_sets_id = ct.tag_sets_id )
                join controversies_id cid on ( c.controversies_id = cid.controversies_id )
            ) on ( m.media_id = cmtm.media_id )
END

    $db->query( <<END );
create or replace view dump_stories_with_types as
    select s.*, m.media_type
        from dump_stories s join dump_media_with_types m on ( s.media_id = m.media_id )
END

}

# generate snapshots for all of the snapshot tables from the temporary dump tables
sub _generate_snapshots_from_temporary_dump_tables
{
    my ( $db, $cd ) = @_;

    map { _create_cd_snapshot( $db, $cd, $_ ) } @_snapshot_tables;
}

# create the controversy_dump row for the current dump
sub _create_controversy_dump($$$$)
{
    my ( $db, $controversy, $start_date, $end_date ) = @_;

    my $cd = $db->query( <<END, $controversy->{ controversies_id }, $start_date, $end_date )->hash;
insert into controversy_dumps 
    ( controversies_id, start_date, end_date, dump_date )
    values ( ?, ?, ?, now() )
    returning *
END

    $cd->{ controversy } = $controversy;

    return $cd;
}

# analyze all of the snapshot tables because otherwise immediate queries to the
# new dump ids offer trigger seq scans
sub _analyze_snapshot_tables
{
    my ( $db ) = @_;

    print STDERR "analyzing tables...\n";

    for my $t ( @_snapshot_tables )
    {
        $db->query( "analyze cd.$t" );
    }
}

# get the tags associated with the controversy through controversy_dump_tags
sub _get_dump_tags
{
    my ( $db, $controversy ) = @_;

    my $tags = $db->query( <<END, $controversy->{ controversies_id } )->hashes;
select distinct t.*
    from tags t
        join controversy_dump_tags cdt on ( t.tags_id = cdt.tags_id and cdt.controversies_id = ? )
END
}

# create a controversy_dump for the given controversy
sub dump_controversy ($$)
{
    my ( $db, $controversies_id ) = @_;

    my $periods = [ qw(custom overall weekly monthly) ];

    my $controversy = $db->find_by_id( 'controversies', $controversies_id )
      || die( "Unable to find controversy '$controversies_id'" );

    # Check if controversy's stories have been processed through Bit.ly
    if ( $controversy->{ process_with_bitly } )
    {
        unless ( MediaWords::Util::Bitly::num_controversy_stories_without_bitly_statistics( $db, $controversies_id ) == 0 )
        {
            die "Not all controversy's $controversies_id stories have been processed with Bit.ly yet.";
        }
    }

    $db->dbh->{ PrintWarn } = 0;    # avoid noisy, extraneous postgres notices from drops

    # Log activity that's about to start
    my $changes = {};
    unless (
        MediaWords::DBI::Activities::log_system_activity( $db, 'cm_dump_controversy', $controversies_id + 0, $changes ) )
    {
        die "Unable to log the 'cm_dump_controversy' activity.";
    }

    my ( $start_date, $end_date ) = _get_default_dates( $db, $controversy );

    my $dump_tags = _get_dump_tags( $db, $controversy );

    my $cd = _create_controversy_dump( $db, $controversy, $start_date, $end_date );

    _write_temporary_dump_tables( $db, $controversy->{ controversies_id } );

    _generate_snapshots_from_temporary_dump_tables( $db, $cd );

    for my $t ( undef, @{ $dump_tags } )
    {
        for my $p ( @{ $periods } )
        {
            _generate_period_dump( $db, $cd, $p, $t );
        }
    }

    _write_date_counts_dump( $db, $cd, 'daily' );
    _write_date_counts_dump( $db, $cd, 'weekly' );

    _analyze_snapshot_tables( $db );
}

1;
