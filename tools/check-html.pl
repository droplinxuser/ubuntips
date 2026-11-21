#!/usr/bin/env perl
# Structural HTML checks for the generated site.
#
# Catches regressions that Lighthouse does not: a missing or duplicated <h1>,
# images without alt attributes, duplicate id attributes, and skipped heading
# levels. Hugo's redirect stubs (aliases) are skipped.
use strict;
use warnings;
use File::Find;

my $root = $ARGV[0] // 'public';
die "check-html: $root does not exist\n" unless -d $root;

my @html;
find(sub { push @html, $File::Find::name if -f && /\.html$/ }, $root);

my $bad = 0;
for my $file (sort @html) {
    open my $fh, '<:encoding(UTF-8)', $file or next;
    local $/;
    my $html = <$fh>;
    close $fh;

    next if $html =~ /http-equiv\s*=\s*["']?refresh/i;    # alias stub

    my @problems;

    my $h1 = () = $html =~ /<h1\b/gi;
    push @problems, "expected one <h1>, found $h1" if $h1 != 1;

    while ($html =~ /<img\b[^>]*>/gi) {
        my $tag = $&;
        push @problems, "img without alt: $tag" unless $tag =~ /\balt\s*=/i;
    }

    my %seen;
    while ($html =~ /\bid\s*=\s*["']?([A-Za-z0-9_:.-]+)/g) {
        my $id = $1;
        push @problems, "duplicate id: $id" if $seen{$id}++;
    }

    my $previous = 0;
    while ($html =~ /<h([1-6])\b/gi) {
        my $level = $1;
        push @problems, "heading jump h$previous -> h$level" if $previous && $level > $previous + 1;
        $previous = $level;
    }

    if (@problems) {
        $bad++;
        print "$file\n";
        print "  - $_\n" for @problems;
    }
}

if ($bad) {
    print "check-html: $bad page(s) with structural issues\n";
    exit 1;
}
print "check-html: all pages have one h1, alt text, unique ids and ordered headings\n";
