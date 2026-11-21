#!/usr/bin/env perl
# Minimal internal-link checker for the generated site.
# Verifies that every relative or root-relative href/src points at a file in
# the build output. External URLs, mailto:, data: and pure fragments are
# ignored on purpose: this guard is for broken internal links, not the network.
use strict;
use warnings;
use File::Find;

my $root = $ARGV[0] // 'public';
die "check-links: $root does not exist\n" unless -d $root;

my @html;
find(sub { push @html, $File::Find::name if -f && /\.html$/ }, $root);

my $bad = 0;
for my $file (sort @html) {
    open my $fh, '<:encoding(UTF-8)', $file or next;
    local $/;
    my $html = <$fh>;
    close $fh;

    while ($html =~ /(?:href|src)\s*=\s*["']?([^"'\s>]+)/g) {
        my $url = $1;
        next if $url =~ m{^(?:[a-z][a-z0-9+.-]*:|//|#)}i;
        $url =~ s/[?#].*$//;
        next unless length $url;

        my $path = $url;
        $path =~ s{^/}{};
        my $target = "$root/$path";

        if ($path eq '' || $path =~ m{/$}) {
            $target = "$root/${path}index.html";
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
        }
    }
}

if ($bad) {
    print "check-links: $bad broken internal link(s)\n";
    exit 1;
}
print "check-links: all internal links resolve\n";
