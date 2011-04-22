#!/usr/bin/perl
# $Revision$
# $Date$
# Copyright (c) 2009-2011 Sergiy Borodych
#
# lastfm2gmb is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3, as
# published by the Free Software Foundation

use strict;
use utf8;
use warnings;

use Encode;
use File::Spec;
use Getopt::Long;
use LWP::UserAgent;
use Net::DBus;
use Storable;
use XML::Simple;

use constant VERSION => 0.03;

binmode(STDOUT, ":encoding(UTF-8)");

my $usage = "lastfm2gmb v".VERSION." (c)2009-2010 Sergiy Borodych
Usage: $0 [-c] [-q|-d debug_level] [-k api_key] [-m mode] -u username
Options:
 -c | --cache           : enable cache results (only for 'playcount & lastplay' mode)
 -d | --debug           : debug level 0..2
 -k | --key             : lastfm API key
 -m | --mode            : import mode: 'a' - all, 'p' - playcount & lastplay, 'l' - loved
 -q | --quiet           : set debug = 0 and no any output
 -r | --rating_loved    : rating for loved tracks (1..100), default 100
 -t | --tmp_dir         : tmp dir for cache store, etc
 -u | --user            : lastfm username, required
Example:
 lastfm2gmb.pl -c -m p -t /var/tmp/lastfm2gmb -u username
";

our %opt;
Getopt::Long::Configure("bundling");
GetOptions(
    'api_uri'           => \$opt{api_uri},  # lastFM API request URL
    'cache|c'           => \$opt{cache},    # enable cache results (only for user.getWeeklyTrackChart method)
    'debug|d=i'         => \$opt{debug},    # debug level 0..2
    'help|h'            => \$opt{help},     # help message ?
    'key|k=s'           => \$opt{key},      # lastfm API key
    'mode|m=s'          => \$opt{mode},     # import mode: a - all, p - playcount & lastplay, l - loved
    'quiet|q'           => \$opt{quiet},    # set debug = 0 and no any output
    'rating_loved|r=i'  => \$opt{rating_loved}, # rating for loved tracks (1..100), default 100
    'tmp_dir|t=s'       => \$opt{tmp_dir},  # tmp dir for cache store, etc
    'user|u=s'          => \$opt{user},     # lastfm username
)
    or die "$usage\n";

print $usage and exit if $opt{help};

# check options
$opt{api_uri} ||= 'http://ws.audioscrobbler.com/2.0/';
$opt{debug} ||= 0;
$opt{key} ||= '4d4019927a5f30dc7d515ede3b3e7f79';       # 'lastfm2gmb' user API key
$opt{key} or die "Need lastfm API key!\n$usage\n";
$opt{mode} ||= 'a';
$opt{mode} = 'pl' if $opt{mode} eq 'a';
$opt{rating_loved} ||= 100;
$opt{tmp_dir} ||=  File::Spec->catdir( File::Spec->tmpdir(), 'lastfm2gmb' );
$opt{user} or die "Need username!\n\n$usage\n";

if ( $opt{cache} and not -d $opt{tmp_dir} ) {
    mkdir($opt{tmp_dir}) or die "Can't create tmp dir $opt{tmp_dir}: $!\n";
}
die "Unknown mode!\n\n$usage\n" unless $opt{mode}=~/[pl]/;

my $bus = Net::DBus->session;
my $service = $bus->get_service("org.gmusicbrowser");
my $gmb_obj = $service->get_object("/org/gmusicbrowser","org.gmusicbrowser");

$| = 1;
my %stats = ( imported_playcount => 0, imported_lastplay => 0, imported_loved => 0, lastfm_plays => 0, skiped => 0 );
my $gmb_library = {};
my $lastfm_library = {};

# get current gmb library
print "Looking up gmb library " unless $opt{quiet};
print "\n" if $opt{debug} >= 2;
foreach my $id ( @{$gmb_obj->GetLibrary} ) {
    my $artist = $gmb_obj->Get([$id,'artist']) or next;
    my $title = $gmb_obj->Get([$id,'title']) or next;
    utf8::decode($artist);
    utf8::decode($title);
    $artist = lc($artist);
    $title = lc($title);
    # TODO: if multiple song's with same names when skip it now
    if ( $gmb_library->{$artist}{$title} ) {
        print "[$id] $artist - $title : found dup - skiped\n" if $opt{debug} >= 2;
        $gmb_library->{$artist}{$title} = { skip => 1 };
        $stats{skiped}++;
    }
    else {
        print "[$id] $artist - $title : " if $opt{debug} >= 2;
        $gmb_library->{$artist}{$title}{id} = $id;
        if ( $opt{mode}=~m/p/o ) {
            $gmb_library->{$artist}{$title}{playcount} = $gmb_obj->Get([$id,'playcount']) || 0;
            $gmb_library->{$artist}{$title}{lastplay} = $gmb_obj->Get([$id,'lastplay']) || 0;
            print "playcount: $gmb_library->{$artist}{$title}{playcount} lastplay: $gmb_library->{$artist}{$title}{lastplay} "
                if $opt{debug} >= 2;
        }
        if ( $opt{mode}=~m/l/o ) {
            $gmb_library->{$artist}{$title}{rating} = $gmb_obj->Get([$id,'rating']) || 0;
            print "rating: $gmb_library->{$artist}{$title}{rating}" if $opt{debug} >= 2;
        }
        print "\n" if $opt{debug} >= 2;
    }
    $stats{gmb_tracks}++;
    print '.' unless $opt{quiet} or $stats{gmb_tracks} % 100;
    last if $stats{gmb_tracks} > 100 and $opt{debug} >= 3;
}
print " $stats{gmb_tracks} tracks ($stats{skiped} skipped as dup)\n" unless $opt{quiet};

our $ua = LWP::UserAgent->new( timeout=>15 );
our $xs = XML::Simple->new(ForceArray=>['track']);

# playcount & lastplay
if ( $opt{mode}=~m/p/ ) {
    # get weekly chart list
    my $charts_data = lastfm_request({method=>'user.getWeeklyChartList'}) or die 'Cant get data from lastfm';
    # add current (last) week to chart list
    my $last_week_from = $charts_data->{weeklychartlist}{chart}[$#{$charts_data->{weeklychartlist}{chart}}]{to};
    my $last_week_to = time() - 1;
    push @{$charts_data->{weeklychartlist}{chart}}, { from=>$last_week_from, to=>$last_week_to }
        if $last_week_from < $last_week_to;
    print "LastFM request 'WeeklyChartList' found ".scalar(@{$charts_data->{weeklychartlist}{chart}})." pages\n"
        unless $opt{quiet};
    # get weekly track chart
    print "LastFM request 'WeeklyTrackChart' pages " unless $opt{quiet};
    foreach my $date ( @{$charts_data->{weeklychartlist}{chart}} ) {
        print "$date->{from}-$date->{to}.." if $opt{debug};
        print '.' unless $opt{quiet};
        my $data = lastfm_get_weeklytrackchart({from=>$date->{from},to=>$date->{to}});
        foreach my $title ( keys %{$data->{weeklytrackchart}{track}} ) {
            my $artist = lc($data->{weeklytrackchart}{track}{$title}{artist}{name}||$data->{weeklytrackchart}{track}{$title}{artist}{content});
            my $playcount = $data->{weeklytrackchart}{track}{$title}{playcount};
            $title = lc($title);
            print "$artist - $title - $playcount\n" if $opt{debug} >= 2;
            if ( $gmb_library->{$artist}{$title} and $gmb_library->{$artist}{$title}{id} ) {
                $lastfm_library->{$artist}{$title}{playcount} += $playcount;
                $lastfm_library->{$artist}{$title}{lastplay} = $date->{from}
                    if ( not $lastfm_library->{$artist}{$title}{lastplay}
                            or $lastfm_library->{$artist}{$title}{lastplay} < $date->{from} );
            }
            $stats{lastfm_plays} += $playcount;
        }
        last if $opt{debug} >= 3;
    }
    print " total $stats{lastfm_plays} plays\n" unless $opt{quiet};
    # clean 'last week' pages workaround
    unlink( glob(File::Spec->catfile($opt{tmp_dir},"WeeklyTrackChart-$opt{user}-$last_week_from-*")) ) unless $opt{debug} >= 2;
}

# loved tracks (rating)
if ( $opt{mode}=~m/l/ ) {
    # first request for get totalPages
    my $data = lastfm_request({method=>'user.getLovedTracks'}) or die 'Cant get data from lastfm';
    die "Something wrong: status = $data->{status}" unless $data->{status} eq 'ok';
    my $pages = $data->{lovedtracks}{totalPages};
    print "LastFM request 'getLovedTracks' found $pages pages ($data->{lovedtracks}{total} tracks)\n" unless $opt{quiet};
    print "LastFM request 'getLovedTracks' pages " unless $opt{quiet};
    for ( my $p = 1; $p <= $pages; $p++ ) {
        print "$p.." if $opt{debug};
        print '.' unless $opt{quiet};
        $data = lastfm_request({method=>'user.getLovedTracks',page=>$p}) or die 'Cant get data from lastfm';
        foreach my $title ( keys %{$data->{lovedtracks}{track}} ) {
            my $artist = lc($data->{lovedtracks}{track}{$title}{artist}{name}||$data->{lovedtracks}{track}{$title}{artist}{content});
            $title = lc($title);
            print "$artist - $title is a loved\n" if $opt{debug} >= 2;
            if ( $gmb_library->{$artist}{$title} and $gmb_library->{$artist}{$title}{id} ) {
                $lastfm_library->{$artist}{$title}{rating} = $opt{rating_loved};
            }
        }
    }
    print "\n" unless $opt{quiet};
}

# import info to gmb
print "Import to gmb " unless $opt{quiet};
foreach my $artist ( sort keys %{$lastfm_library} ) {
    print '.' unless $opt{quiet};
    print "$artist\n" if $opt{debug} >= 2;
    foreach my $title ( keys %{$lastfm_library->{$artist}} ) {
        my $e;
        print " $title - $lastfm_library->{$artist}{$title}{playcount} <=> $gmb_library->{$artist}{$title}{playcount}\n" if $opt{debug} >= 2;
        # playcount
        if ( $lastfm_library->{$artist}{$title}{playcount}
                and $lastfm_library->{$artist}{$title}{playcount} > $gmb_library->{$artist}{$title}{playcount} ) {
            print "  $artist - $title : playcount : $gmb_library->{$artist}{$title}{playcount} -> $lastfm_library->{$artist}{$title}{playcount}\n" if $opt{debug};
            $gmb_obj->Set([ $gmb_library->{$artist}{$title}{id}, 'playcount', $lastfm_library->{$artist}{$title}{playcount}])
                or $e++ and warn " error setting 'playcount' for track ID $gmb_library->{$artist}{$title}{id}\n";
            $e ? $stats{errors}++ : $stats{imported_playcount}++;
        }
        # lastplay
        if ( $lastfm_library->{$artist}{$title}{lastplay}
                and $lastfm_library->{$artist}{$title}{lastplay} > $gmb_library->{$artist}{$title}{lastplay} ) {
            print "  $artist - $title : lastplay : $gmb_library->{$artist}{$title}{lastplay} -> $lastfm_library->{$artist}{$title}{lastplay}\n" if $opt{debug};
            $gmb_obj->Set([ $gmb_library->{$artist}{$title}{id}, 'lastplay', $lastfm_library->{$artist}{$title}{lastplay} ])
                or $e++ and warn " error setting 'lastplay' for track ID $gmb_library->{$artist}{$title}{id}\n";
            $e ? $stats{errors}++ : $stats{imported_lastplay}++;
        }
        # loved
        if ( $lastfm_library->{$artist}{$title}{rating}
                and $lastfm_library->{$artist}{$title}{rating} > $gmb_library->{$artist}{$title}{rating} ) {
            $gmb_obj->Set([ $gmb_library->{$artist}{$title}{id}, 'rating', $lastfm_library->{$artist}{$title}{rating}])
                            or $e++ and warn " error setting 'rating' for track ID $gmb_library->{$artist}{$title}{id}\n";
            $e ? $stats{errors}++ : $stats{imported_loved}++;
        }
    }
}

print "\nImported : playcount - $stats{imported_playcount}, lastplay - $stats{imported_lastplay}, loved - $stats{imported_loved}. " . ($stats{errors} ? $stats{errors} : 'No') . " errors detected.\n"
    unless $opt{quiet};


# lastfm request
sub lastfm_request {
    my ($params) = @_;
    my $url = "$opt{api_uri}?api_key=$opt{key}&user=$opt{user}";
    if ( $params ) {
        $url .= '&'.join('&',map("$_=$params->{$_}",keys %{$params}));
    }
    my $response = $ua->get($url);
    if ( $response->is_success ) {
        return $xs->XMLin($response->decoded_content);
    }
    else {
        warn "Error: Can't get url '$url' - " . $response->status_line."\n";
        return;
    }
}


# get weekly track chart list
sub lastfm_get_weeklytrackchart {
    my ($params) = @_;
    my $filename = File::Spec->catfile($opt{tmp_dir}, "WeeklyTrackChart-$opt{user}-$params->{from}-$params->{to}.data");
    my $data;
    if ( $opt{cache} and -e $filename ) {
        $data = retrieve($filename);
    }
    else {
        $data = lastfm_request({method=>'user.getWeeklyTrackChart',%{$params}}) or die 'Cant get data from lastfm';
        # TODO : strip some data, for left only need info like: artist, name, playcount
        store $data, $filename if $opt{cache};
    }
    return $data;
}
