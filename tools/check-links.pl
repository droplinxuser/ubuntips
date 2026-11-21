#!/usr/bin/env perl
# Internal-link checker for the generated site.
#
# Verifies that every relative or root-relative href/src points at a file in
# the build output, and that any #fragment resolves to an id in the target
# document. External URLs, mailto: and data: are ignored: this guard is for
# internal links and anchors, not the network.
use strict;
use warnings;
use File::Find;

my $root = $ARGV[0] // 'public';
die "check-links: $root does not exist\n" unless -d $root;

my @html;
find(sub { push @html, $File::Find::name if -f && /\.html$/ }, $root);

my %cache;
sub contents {
    my ($file) = @_;
    return $cache{$file} if exists $cache{$file};
    open my $fh, '<:encoding(UTF-8)', $file or return ($cache{$file} = '');
    local $/;
    my $html = <$fh>;
    close $fh;
    return ($cache{$file} = $html);
}

my $bad = 0;
for my $file (sort @html) {
    my $html = contents($file);

    while ($html =~ /(?:href|src)\s*=\s*["']?([^"'\s>]+)/g) {
        my $url = $1;
        next if $url =~ m{^(?:[a-z][a-z0-9+.-]*:|//)}i;

        my $path = $url;
        my $frag = '';
        if ($path =~ s/#(.*)$//) {
            $frag = $1;
        }
        $path =~ s/\?.*$//;

        my $target;
        if ($path eq '') {
            next unless length $frag;
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
                next;
            }
        }

        next unless length $frag;
        next if $frag =~ /^:/;    # text fragments

        my $anchor = $frag;
        $anchor =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        my $quoted = quotemeta $anchor;
        my $body = contents($target);
        unless ($body =~ /\bid\s*=\s*["']?$quoted["']?(?=[\s>\/])/) {
            warn "missing anchor: #$anchor (in $file -> $target)\n";
            $bad++;
        }
    }
}

if ($bad) {
    print "check-links: $bad broken internal link or anchor\n";
    exit 1;
}
print "check-links: all internal links and anchors resolve\n";
