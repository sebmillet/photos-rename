#!/usr/bin/perl

#
# Copyright 2023 Sébastien Millet <sebastien.millet@gmail.com>
#
# Rename photo files and (if available) the corresponding RAW file.
#

#    This file 'ren.pl' is part of 'photos-rename'.
#
#    'photos-rename' is free software: you can redistribute it and/or modify it under the
#    terms of the GNU General Public License as published by the Free Software Foundation,
#    either version 3 of the License, or (at your option) any later version.
#
#    'photos-rename' is distributed in the hope that it will be useful, but WITHOUT ANY
#    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
#    PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License along with
#    'photos-rename'. If not, see <https://www.gnu.org/licenses/>.

use utf8;
use 5.016;

use strict;
use warnings;

use Readonly;

Readonly my $VERSION => '0.5';

# MANAGE INPUT: raw extension, exif field name and format of image datetime

Readonly my $RAW_EXT             => '.RW2';
Readonly my $EXIF_DATETIME_FIELD => 'DateTimeOriginal';

# Strptime format
Readonly my $EXIT_DATETIME_FORMAT => '%Y:%m:%d %H:%M:%S';

# MANAGE OUTPUT: what are the jpeg files renamed into

# strftime format
Readonly my $NEW_NAME_BASE_FORMAT => '%Y_%m%d_%H%M%S';

use Getopt::Long qw(:config no_ignore_case bundling);

use Image::ExifTool;
use File::Basename;
use File::Spec::Functions 'catfile';
use Image::ExifTool qw(:Public);
use DateTime::Format::Strptime;

sub usage {
    my $u = <<"EOF";
Usage: ren.pl [OPTIONS...] [DIRECTORY]
Rename JPEG files as per their exif creation date.
Also rename corresponding raw files if it exists.

  -h, --help     Print this message and quit
  -V, --version  Print version information and quit
EOF
    print( STDERR $u );
}

my ( $opt_help, $opt_version, $opt_debug );

if (
    !GetOptions(
        'help|h'    => \$opt_help,
        'version|V' => \$opt_version,
        'debug|d'   => \$opt_debug
    )
  )
{
    usage, exit 1;
}

print( STDERR "ren.pl version $VERSION\n" ), exit 0 if $opt_version;
usage, exit 0 if $opt_help;

my $directory_to_process;
if ( !@ARGV ) {
    $directory_to_process = '.';
}
elsif ( @ARGV >= 2 ) {
    print STDERR "Trailing arguments. "
      . "You can process only one directory at a time.\n";
    usage;
    exit 10;
}
else {
    $directory_to_process = $ARGV[0];
}

# From
#   https://stackoverflow.com/questions/7486470/how-to-parse-a-string-into-a-datetime-object-in-perl
my $parser =
  DateTime::Format::Strptime->new( pattern => $EXIT_DATETIME_FORMAT );

if ( !-d $directory_to_process ) {
    print STDERR "Directory '$directory_to_process' does not exist. Aborted.\n";
    exit 11;
}

sub dbg() {
    return unless $opt_debug;
    print @_, "\n";
}

# Equivalent to '-f' but case insensitive no matter the OS.
# An optional, third parameter is to activate use of cached data.
# USE THIS THIRD PARAMETER WITH CAUTION!
#   When using cached data, consecutive calls for the same directory will rely
#   on cached data (only the first call will read directory content).
#   That means, file operations done in the directory in-between won't be
#   reflected.
sub check_file_exists_case_insensitive() {
    state $cached_dir_name = undef;
    state %cached_dir_hash = ();

    my ( $dir, $file, $use_cache ) = @_;

    print "dir: [$dir], file: [$file]\n";

    $use_cache //= 0;

    if (   ( !defined $cached_dir_name )
        or ( ( $cached_dir_name // '' ) ne $dir )
        or ( !$use_cache ) )
    {
        %cached_dir_hash = ();

        # Yes, we store undef values in the hash, as we don't need more.
        # The value doesn't matter, all we want to know later is, whether or
        # not the key exists.
        undef $cached_dir_hash{ lc($_) } for (<${dir}*>);
        $cached_dir_name = $dir;

        #        print STDERR "** READ DIRECTORY **\n";
    }
    else {
        #        print STDERR "** use cached directory data **\n";
    }

    return exists $cached_dir_hash{ lc($file) };
}

# Convert an integer number into a 'special base-26-based' representation using
# symbols 'a' to 'z'.
# That is, convert
#   0 to 'a'
#   1 to 'b'
#   ...
#   25 to 'z'
#   26 to 'aa'
#   27 to 'ab'
#   ...
#   and so on
# The special value -1 (-1 is the only negative value allowed) returns an empty
# string.
sub int_to_letters {
    my $n = shift;

    die "Negative value (except for -1) not allowed ($n)" if $n < -1;
    die "Non-integer value not allowed ($n)"              if int($n) != $n;

    return '' if $n == -1;

    my $ret = '';
    do {
        $ret = chr( ord('a') + ( $n % 26 ) ) . $ret;
        $n   = int( $n / 26 ) - 1;
    } while ( $n >= 0 );
    return $ret;
}

#for (my $i = -1; $i < 800; $i++) {
#    print "$i -> ", &int_to_letters($i), "\n";
#}
#exit;

&dbg("Processing directory '$directory_to_process'");

my %targets;
my @rename_list;
my $glob_pattern = catfile( $directory_to_process, '*' );
while ( my $file = glob($glob_pattern) ) {

    &dbg('');
    &dbg("-- File:          $file");

    if ( $file !~ /\.(jpg|jpeg)$/i ) {
        &dbg("   Skipped.");
        next;
    }

    my ( $base, $dir, $ext ) = fileparse( $file, '\.[^.]*' );

    #&dbg("     Base:           $base");
    #&dbg("     Dir:            $dir");
    #&dbg("     Ext:            $ext");

    my $exif_data = ImageInfo($file);

    #foreach (keys %$exif_data) {
    #    print "$_ => $$exif_data{$_}";
    #}
    #exit;

    my $has_exif_data = exists( $$exif_data{$EXIF_DATETIME_FIELD} );
    if ( !$has_exif_data ) {
        &dbg( "   EXIF has no 'DateTimeOriginal' field ",
            "(not a jpeg?). Skipped." );
        next;
    }

    my $image_date_str = $$exif_data{$EXIF_DATETIME_FIELD};

    &dbg("   Datetime:      [$image_date_str]");

    my $image_date_obj  = $parser->parse_datetime($image_date_str);
    my $has_parsed_date = defined($image_date_obj);

    if ( !$has_parsed_date ) {
        &dbg("   Unable to parse EXIF Datetime. Skipped.");
        next;
    }

    my $raw_file = catfile( $dir, $base ) . $RAW_EXT;
    my $has_raw_file =
      &check_file_exists_case_insensitive( $dir, $raw_file, 1 );

    my $new_name_base = $image_date_obj->strftime($NEW_NAME_BASE_FORMAT);

    my $file_target_name;
    my $raw_file_target_name;
    my $dedup_int = -1;
    my $file_target_exists;
    my $raw_target_exists;
    do {
        my $dedup_postfix = &int_to_letters($dedup_int);

        $file_target_name =
          catfile( $dir, $new_name_base ) . $dedup_postfix . $ext;
        $file_target_exists =
          &check_file_exists_case_insensitive( $dir, $file_target_name )
          || exists $targets{$file_target_name};

        $raw_target_exists = 0;
        if ($has_raw_file) {
            $raw_file_target_name =
              catfile( $dir, $new_name_base ) . $dedup_postfix . $RAW_EXT;
            $raw_target_exists =
              &check_file_exists_case_insensitive( $dir, $raw_file_target_name )
              || exists $targets{$raw_file_target_name};
        }

        $dedup_int++;

    } while ( $file_target_exists or $raw_target_exists );

    undef $targets{$file_target_name};
    undef $targets{$raw_file_target_name} if $has_raw_file;

    &dbg("   New name base: $new_name_base");
    &dbg("   Target:        $file_target_name");
    &dbg( "   Raw name:      $raw_file ",
        ( $has_raw_file ? '(exists)' : '(does not exist)' ) );
    if ($has_raw_file) {
        &dbg("   Raw target:    $raw_file_target_name");
    }

    push @rename_list, [ $file, $file_target_name ];
    if ($has_raw_file) {
        push @rename_list, [ $raw_file, $raw_file_target_name ];
    }
}

&dbg('');

for my $elem (@rename_list) {
    print "$$elem[0] -> $$elem[1]\n";
}

my $s0 = $rename_list[0][0];
my $d0 = $rename_list[0][1];
say $s0;
say $d0;

#rename $s0, $d0
