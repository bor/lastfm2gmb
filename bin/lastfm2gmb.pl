#!/usr/bin/perl
# $Revision$
# $Date$
# Copyright (c) 2009 Sergiy Borodych
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

use constant VERSION => 0.02;

binmode(STDOUT, ":utf8");

my $usage = "lastfm2gmb v".VERSION." (c)2009 Sergiy Borodych
Usage: $0 [-c] [-q|-d debug_level] [-k api_key] -u username
Options:
 -c : enable cache results (only for user.getWeeklyTrackChart method)
 -d : debug level 0..2
 -k : lastfm api key
 -q : set debug = 0 and no any output
 -t : tmp dir for cache store, etc
 -u : lastfm username, required
";

our %opt;
Getopt::Long::Configure("bundling");
GetOptions(
    'api_uri'       => \$opt{api_uri},  # lastFM API request URL
    'cache|c'       => \$opt{cache},    # enable cache results (only for user.getWeeklyTrackChart method)
    'debug|d=i'     => \$opt{debug},    # debug level 0..2
    'help|h'        => \$opt{help},     # help message ?
    'key|k=s'       => \$opt{key},      # lastfm api key
    'quiet|q'       => \$opt{quiet},    # set debug = 0 and no any output
    'tmp_dir|t=s'   => \$opt{tmp_dir},  # tmp dir for cache store, etc
    'user|u=s'      => \$opt{user},     # lastfm username
)
    or die "$usage\n";

$opt{api_uri} ||= 'http://ws.audioscrobbler.com/2.0/';
$opt{debug} ||= 0;
$opt{key} ||= '4d4019927a5f30dc7d515ede3b3e7f79';       # 'lastfm2gmb' user api key
$opt{key} or die "Need api key!\n$usage\n";
$opt{tmp_dir} ||=  File::Spec->catdir( File::Spec->tmpdir(), 'lastfm2gmb' );
$opt{user} or die "Need username!\n$usage\n";

if ( $opt{cache} and ! -d $opt{tmp_dir} ) {
    mkdir($opt{tmp_dir}) or die "Can't create tmp dir $opt{tmp_dir}: $!";
}

my $bus = Net::DBus->session;
my $service = $bus->get_service("org.gmusicbrowser");
my $gmb_obj = $service->get_object("/org/gmusicbrowser","org.gmusicbrowser");

$| = 1;
my %stats = ( imported_playcount => 0, imported_lastplay => 0, lastfm_plays => 0 );
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
    my $playcount = $gmb_obj->Get([$id,'playcount']) || 0;
    my $lastplay = $gmb_obj->Get([$id,'lastplay']) || 0;
    # TODO: if multiple song's with same names when skip it now
    if ( $gmb_library->{$artist}{$title} ) {
        $gmb_library->{$artist}{$title} = { skip => 1 };
    }
    else {
        $gmb_library->{$artist}{$title} = { id => $id, playcount => $playcount, lastplay => $lastplay };
    }
    print "[$id] $artist - $title : playcount : $playcount : lastplay : $lastplay\n" if $opt{debug} >= 2;
    $stats{gmb_tracks}++;
    print '.' unless $opt{quiet} or $stats{gmb_tracks} % 100;
    last if $stats{gmb_tracks} > 100 and $opt{debug} >= 3;
}
print " $stats{gmb_tracks} tracks\n" unless $opt{quiet};

our $ua = LWP::UserAgent->new( timeout=>15 );
our $xs = XML::Simple->new();

# get weekly chart list
my $charts_data = lastfm_request({method=>'user.getWeeklyChartList'}) or die 'Cant get data from lastfm';
# add current (last) week
my $last_week_from = $charts_data->{weeklychartlist}{chart}[$#{$charts_data->{weeklychartlist}{chart}}]{to};
push @{$charts_data->{weeklychartlist}{chart}}, { from=>$last_week_from, to=>time() }
    if $last_week_from < time();
print "LastFM request 'WeeklyChartList' found ".scalar(@{$charts_data->{weeklychartlist}{chart}})." pages\n"
    unless $opt{quiet};

# clean 'last week' pages workaround
unlink(glob(File::Spec->catfile($opt{tmp_dir},"WeeklyTrackChart-$opt{user}-$last_week_from-*")));

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
                if ( !$lastfm_library->{$artist}{$title}{lastplay}
                        or $lastfm_library->{$artist}{$title}{lastplay} < $date->{from} );
        }
        $stats{lastfm_plays} += $playcount;
    }
    last if $opt{debug} >= 3;
}
print " total $stats{lastfm_plays} plays\n" unless $opt{quiet};

# import info to gmb
print "Import to gmb " unless $opt{quiet};
foreach my $artist ( sort keys %{$lastfm_library} ) {
    print '.' unless $opt{quiet};
    print "$artist\n" if $opt{debug} >= 2;
    foreach my $title ( keys %{$lastfm_library->{$artist}} ) {
        my $e;
        print " $title - $lastfm_library->{$artist}{$title}{playcount} <=> $gmb_library->{$artist}{$title}{playcount}\n" if $opt{debug} >= 2;
        if ( $lastfm_library->{$artist}{$title}{playcount} > $gmb_library->{$artist}{$title}{playcount} ) {
            print "  $artist - $title : playcount : $gmb_library->{$artist}{$title}{playcount} -> $lastfm_library->{$artist}{$title}{playcount}\n" if $opt{debug};
            $gmb_obj->Set([ $gmb_library->{$artist}{$title}{id}, 'playcount', $lastfm_library->{$artist}{$title}{playcount}])
                or $e++ and warn " error setting 'playcount' for track ID $gmb_library->{$artist}{$title}{id}\n";
            $e ? $stats{errors}++ : $stats{imported_playcount}++;
        }
        if ( $lastfm_library->{$artist}{$title}{lastplay} > $gmb_library->{$artist}{$title}{lastplay} ) {
            print "  $artist - $title : lastplay : $gmb_library->{$artist}{$title}{lastplay} -> $lastfm_library->{$artist}{$title}{lastplay}\n" if $opt{debug};
            $gmb_obj->Set([ $gmb_library->{$artist}{$title}{id}, 'lastplay', $lastfm_library->{$artist}{$title}{lastplay} ])
                or $e++ and warn " error setting 'lastplay' for track ID $gmb_library->{$artist}{$title}{id}\n";
            $e ? $stats{errors}++ : $stats{imported_lastplay}++;
        }
        #if ( $lastfm_library->{$artist}{$title}{loved} ) {
        #    # TODO
        #}
    }
}

print "\nImported : playcount - $stats{imported_playcount} tracks, lastplay - $stats{imported_lastplay} tracks. " . ($stats{errors} ? $stats{errors} : 'No') . " errors detected.\n"
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
