#!/usr/bin/perl
# $Revision$
# $Date$

use strict;
use utf8;
use warnings;

use Encode;
use Getopt::Long;
use LWP::UserAgent;
use Net::DBus;
use XML::Simple;

binmode(STDOUT, ":utf8");

my $usage = "Usage: $0 [-q|-d debug_level] [-k api_key] -u username";

our %opt;
Getopt::Long::Configure("bundling");
GetOptions(
#    'cache|c'       => \$opt{cache},
    'debug|d=i'     => \$opt{debug},
    'help|h'        => \$opt{help},
    'key|k=s'       => \$opt{key},
    'quiet|q'       => \$opt{quiet},
    'user|u=s'      => \$opt{user},
)
    or die "$usage\n";

$opt{debug} ||= 0;
$opt{key} ||= '8d5f0e0916bf3c9f573b1a7c7dd0a8a8';
$opt{key} or die "Need api key!\n$usage\n";
$opt{user} or die "Need username!\n$usage\n";

# lastFM URL
our $gettracks_url = "http://ws.audioscrobbler.com/2.0/?method=library.gettracks&api_key=$opt{key}&user=$opt{user}";

my $bus = Net::DBus->session;
my $service = $bus->get_service("org.gmusicbrowser");
my $object = $service->get_object("/org/gmusicbrowser","org.gmusicbrowser");

# get current gmb library
$| = 1;
print "Looking up gmb library " unless $opt{quiet};
my $count = 0;
my $library = {};
foreach my $id ( @{$object->GetLibrary} ) {
    my $artist = $object->Get([$id,'artist']) or next;
    my $title = $object->Get([$id,'title']) or next;
    utf8::decode($artist);
    utf8::decode($title);
    $artist = lc($artist);
    $title = lc($title);
    my $playcount = $object->Get([$id,'playcount']) || 0;
    # TODO: if multiple song's with same names when skip it now
    if ( $library->{$artist}{$title} ) {
        $library->{$artist}{$title} = { skip => 1 };
    }
    else {
        $library->{$artist}{$title} = { id => $id, playcount => $playcount };
    }
    warn "$id -> $artist - $title = $playcount\n" if $opt{debug} >= 2;
    $count++;
    print '.' unless $opt{quiet} or $count % 100;
}
print " $count tracks\n" unless $opt{quiet};

$count = 0;
my $totalplays = 0;
my $error = 0;

our $ua = LWP::UserAgent->new;
$ua->timeout(15);
our $xs = XML::Simple->new();
# first request for get totalPages
my $data = lastfm_request() or die "Cant get data from lastfm";
die "Something wrong: status = $data->{status}" unless $data->{status} eq 'ok';
my $pages = $data->{tracks}{totalPages};
print "LastFM found $pages pages, ~".($pages*$data->{tracks}{perPage})." tracks\n" unless $opt{quiet};

for ( my $p = 1; $p <= $pages; $p++ ) {
    print "Page $p\n";
    my $data = lastfm_request({page=>$p}) or die "Cant get data from lastfm";
    foreach my $title ( keys %{$data->{tracks}{track}} ) {
        my $artist = lc($data->{tracks}{track}{$title}{artist}{name});
        #my $lastplay = $data->{tracks}{track}{$title}{};
        my $playcount = $data->{tracks}{track}{$title}{playcount};
        $title = lc($title);
        $totalplays += $playcount;
        warn "$artist - $title - $playcount\n" if $opt{debug} >= 2;
        if ( $library->{$artist}{$title} and $library->{$artist}{$title}{id} ) {
            my $e;
            warn "$artist - $title - $playcount <=> $library->{$artist}{$title}{playcount}\n" if $opt{debug};
            if ( $playcount > $library->{$artist}{$title}{playcount} ) {
                print "  $artist - $title : $library->{$artist}{$title}{playcount} -> $playcount\n";
                $object->Set([ $library->{$artist}{$title}{id}, 'playcount', $playcount ])
                    or $e++ and warn " error setting 'playcount' to $playcount for track ID $library->{$artist}{$title}{id}\n";
                $e ? $error++ : $count++;
            }
            #if ( $lastplay > $library->{$artist}{$title}{lastplay} ) {
            #    $object->Set([ $library->{$artist}{$title}{id}, 'lastplay', $lastplay ])
            #        or $e++ and warn " error setting 'lastplay' to $lastplay for track ID $library->{$artist}{$title}{id}\n";
            #}
            #elsif ( $library->{$artist}{$title}{lastplay} > $data->{tracks}{track}{$title}{lastplay} ) {
                # TODO: submit to last fm
            #}
        }
    }
    last if $opt{debug} and $p >= 2;
}
print "LastFM total plays $totalplays.\nImported playcount for $count tracks. ". ($error ? $error : 'No'). " errors detected.\n";


sub lastfm_request {
    my ($params) = @_;
    my $url = $gettracks_url;
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
