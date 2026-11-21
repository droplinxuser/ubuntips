#!/usr/bin/env perl
# Internal-link checker for the generated site.
#
# Verifies that every relative or root-relative href/src (and every candidate in
# a srcset) points at a file in the build output, and that any #fragment
# resolves to an id in the target document. External URLs, mailto: and data:
# are ignored: this guard is for internal links and anchors, not the network.
use strict;
use warnings;
use File::Find;

my $root = $ARGV[0] // 'public';
die "check-links: $root does not exist\n" unless -d $root;

my @html;
find(sub { push @html, $File::Find::name if -f && /\.html$/ }, $root);

my (%cache, $bad);
$bad = 0;

sub contents {
    my ($file) = @_;
    return $cache{$file} if exists $cache{$file};
    open my $fh, '<:encoding(UTF-8)', $file or return ($cache{$file} = '');
    local $/;
    my $html = <$fh>;
    close $fh;
    return ($cache{$file} = $html);
}

sub check_url {
    my ($url, $file) = @_;
    return if $url =~ m{^(?:[a-z][a-z0-9+.-]*:|//)}i;

    my $path = $url;
    my $frag = '';
    if ($path =~ s/#(.*)$//) {
        $frag = $1;
    }
    $path =~ s/\?.*$//;

    my $target;
    if ($path eq '') {
        return unless length $frag;
        $target = $file;
    } else {
        my $rel = $path;
        $rel =~ s{^/}{};
        $target = "$root/$rel";
        if ($rel eq '' || $rel =~ m{/$}) {
            $target = "$root/${rel}index.html";
        } elsif (!-e $target) {
            if (-e "$target/index.html") {
                $target = "$target/index.html";
            } elsif (-e "$target.html") {
                $target = "$target.html";
            }
        }
        unless (-e $target) {
            warn "missing: $url (in $file)\n";
            $bad++;
            return;
        }
    }

    return unless length $frag;
    return if $frag =~ /^:/;    # text fragments

    my $anchor = $frag;
    $anchor =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    my $quoted = quotemeta $anchor;
    my $body = contents($target);
    unless ($body =~ /\bid\s*=\s*["']?$quoted["']?(?=[\s>\/])/) {
        warn "missing anchor: #$anchor (in $file -> $target)\n";
        $bad++;
    }
}

for my $file (sort @html) {
    my $html = contents($file);

    while ($html =~ /\b(?:href|src)\s*=\s*["']?([^"'\s>]+)/g) {
        check_url($1, $file);
    }

    while ($html =~ /\bsrcset\s*=\s*["']?([^"'>]+)/g) {
        for my $candidate (split /,/, $1) {
            $candidate =~ s/^\s+|\s+$//g;
            my ($url) = split /\s+/, $candidate;
            next unless defined $url && length $url;
            check_url($url, $file);
        }
    }
}

if ($bad) {
    print "check-links: $bad broken internal link or anchor\n";
    exit 1;
}
print "check-links: all internal links, anchors and srcsets resolve\n";
