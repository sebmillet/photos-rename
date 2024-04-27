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

# Version history
#   0.5      Initial writing
#   0.9      Pre-release, can do the renaming, provides options -e, -z, -e, -v
#   0.9.1    Add -d option in -h output
#            Create --trace option (and document in -h)
#            Dies at any warning
#            In trace output, in the raw EXIF field output, adds EXIF tag IDs (in addition
#            to tag names)

use utf8;
use 5.016;

use strict;
use warnings FATAL => 'all';

use Readonly;

Readonly my $VERSION => '0.9.1';

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
use Scalar::Util qw(looks_like_number);

sub usage {
    my $u = <<"EOF";
Usage: ren.pl [OPTIONS...] [DIRECTORY]
Rename JPEG files as per their exif creation date.
Also rename corresponding raw file if it exists.

Raw files have the extension '$RAW_EXT'.

The renaming scheme is '$NEW_NAME_BASE_FORMAT' (strftime format).
  Example of target name: 2023_0803_150850.JPG for a photo taken
  August 3rd 2023 at 15:08:50.
  You may update the variable \$NEW_NAME_BASE_FORMAT in this script to change it.

When multiple files have the same target name, rename with appendicies 'a', 'b' and so on.

  -y, --yes       Don't ask for confirmation before renaming
  -z              Dry run (don't rename files)
  -e, --extension Enforce renamed file extension. Can be jpeg or jpg or any combination
                  with upper case and lower case letters (JPEG, Jpeg, JPG, Jpg, JpEg, JpG,
                  ...)
                  Applies only to main file (jpeg).
                  Raw file, if it exists, is renamed keeping its extension as is.
  -h, --help      Print this message and quit
  -V, --version   Print version information and quit
  -v, --verbose   More verbose output
  -d, --debug     Debug output
      --trace     Trace output
                  Implies -d, but produces even more output than -d
EOF
    print( STDERR $u );
}

my ( $opt_dont_ask_for_confirmation,
    $opt_dry_run, $opt_enforce_extension, $opt_verbose, $opt_help, $opt_version,
    $opt_debug,   $opt_trace );

if (
    !GetOptions(
        'y|yes'         => \$opt_dont_ask_for_confirmation,
        'z'             => \$opt_dry_run,
        'e|extension=s' => \$opt_enforce_extension,
        'v'             => \$opt_verbose,
        'help|h'        => \$opt_help,
        'version|V'     => \$opt_version,
        'debug|d'       => \$opt_debug,
        'trace'         => \$opt_trace
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
      . "You can process only one directory at a time. Aborted.\n";
    usage;
    exit 10;
}
else {
    $directory_to_process = $ARGV[0];
}

$opt_enforce_extension //= '';
if ( $opt_enforce_extension !~ m/^\.?(?:|jpeg|jpg)$/i ) {
    print STDERR "Not allowed extension '$opt_enforce_extension'. Aborted.\n";
    usage;
    exit 12;
}
if ( $opt_enforce_extension ne '' ) {
    $opt_enforce_extension = '.' . $opt_enforce_extension
      if $opt_enforce_extension !~ m/^\./;
}

# From
#   https://stackoverflow.com/questions/7486470/how-to-parse-a-string-into-a-datetime-object-in-perl
my $parser =
  DateTime::Format::Strptime->new( pattern => $EXIT_DATETIME_FORMAT );

if ( !-d $directory_to_process ) {
    print STDERR "Directory '$directory_to_process' does not exist. Aborted.\n";
    exit 11;
}

$opt_debug = 1 if $opt_trace;

sub dbg() {
    return unless $opt_debug;
    print @_, "\n";
}

sub trace() {
    return unless $opt_trace;
    print @_, "\n";
}

# Equivalent to '-e' but case insensitive no matter the OS.
#
# An optional, third parameter is to activate use of cached data.
# USE THIS THIRD PARAMETER WITH CAUTION!
#   When using cached data, consecutive calls for the same directory will rely
#   on cached data (only the first call will read directory content).
#   THAT MEANS, FILE OPERATIONS DONE IN THE DIRECTORY IN-BETWEEN WON'T BE
#   REFLECTED.
#
# About calling context
#   If function is called in scalar context, returns 0 or 1.
#   If function is called in list context, returns a list made of a first element, 0 or 1,
#     and a second element that is the original name (with original case).
#     Obviously if the file is not found (first element in the returned list is 0), the
#     second one is undef.
sub check_file_exists_case_insensitive() {
    state $cached_dir_name = undef;
    state %cached_dir_hash = ();

    my ( $dir, $file, $use_cache ) = @_;

    if ( $file eq '' ) {

# FIXME?
#   Not sure the below makes sense. A simple 'return 0' would be fine I guess, no
#   matter the calling context.
        if (wantarray) {
            return ( 0, undef );
        }
        else {
            return 0;
        }

    }

    $use_cache //= 0;

    if (   ( !defined $cached_dir_name )
        or ( ( $cached_dir_name // '' ) ne $dir )
        or ( !$use_cache ) )
    {
        %cached_dir_hash = ();

        $cached_dir_hash{ lc($_) } = $_ for (<${dir}*>);
        $cached_dir_name = $dir;

        #        print STDERR "** READ DIRECTORY **\n";
    }
    else {
        #        print STDERR "** use cached directory data **\n";
    }

    if ( !wantarray ) {
        return exists $cached_dir_hash{ lc($file) };
    }
    else {
        return (
            exists $cached_dir_hash{ lc($file) },
            $cached_dir_hash{ lc($file) }
        );
    }
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

if ($opt_verbose) {
    print "Processing directory '$directory_to_process'\n";
}

my %targets;
my @rename_list;
my $glob_pattern = catfile( $directory_to_process, '*' );
while ( my $file = glob($glob_pattern) ) {

    &dbg('');
    &dbg("-- File:          $file");

    if ( $file !~ /\.(?:jpg|jpeg)$/i ) {
        &dbg("   Skipped (no jpeg extension).");
        next;
    }
    if ( !-f $file ) {
        &dbg("   Skipped (no regular file).");
        next;
    }

    my ( $base, $dir, $ext ) = fileparse( $file, '\.[^.]*' );

    &trace("     Base:           $base");
    &trace("     Dir:            $dir");
    &trace("     Ext:            $ext");

    my $exif_tool = Image::ExifTool->new;
    my $exif_data = $exif_tool->ImageInfo($file);

    if ($opt_trace) {
        foreach ( sort keys %$exif_data ) {
            my $t = $exif_tool->GetTagID($_);
            my $exif_id_hexstr;
            $exif_id_hexstr = '-';
            $exif_id_hexstr = sprintf( '0x%04x', $t ) if looks_like_number($t);
            print "\t\t$_ \[$exif_id_hexstr\] => $$exif_data{$_}\n";
        }
    }

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
    my ( $has_raw_file, $raw_file_with_original_case ) =
      &check_file_exists_case_insensitive( $dir, $raw_file, 1 );
    my $my_raw_ext;
    if ($has_raw_file) {
        $my_raw_ext = $raw_file_with_original_case =~ s/.*(\.[^.]+)$/$1/r;
    }

    my $new_name_base = $image_date_obj->strftime($NEW_NAME_BASE_FORMAT);

    my $file_target_name;
    my $raw_file_target_name;
    my $dedup_int = -1;
    my $file_target_exists;
    my $raw_target_exists;
    do {
        my $dedup_postfix = &int_to_letters($dedup_int);

        my $my_ext =
          ( $opt_enforce_extension eq '' ? $ext : $opt_enforce_extension );

        $file_target_name =
          catfile( $dir, $new_name_base ) . $dedup_postfix . $my_ext;

        my $alt_file_target_name =
            catfile( $dir, $new_name_base )
          . $dedup_postfix
          . ( ( $my_ext =~ m/.jpg/i ) ? '.jpeg' : '.jpg' );

# The below line could seem useless, but it is not.
# When we enforce target extension (-e option of this script), for a file not
# using target extension (for example file is 2023_0715_142000.jpg and enforced
# extension is jpeg) the alternate file name WILL BE THE SAME as the original file
# name.
        $alt_file_target_name = '' if $alt_file_target_name eq $file;

        $file_target_exists =
             &check_file_exists_case_insensitive( $dir, $file_target_name )
          || &check_file_exists_case_insensitive( $dir, $alt_file_target_name )
          || exists $targets{$file_target_name};

        $file_target_exists = 0 if $file eq $file_target_name;

        $raw_target_exists = 0;
        if ($has_raw_file) {
            $raw_file_target_name =
              catfile( $dir, $new_name_base ) . $dedup_postfix . $my_raw_ext;
            $raw_target_exists =
              &check_file_exists_case_insensitive( $dir, $raw_file_target_name )
              || exists $targets{$raw_file_target_name};

            $raw_target_exists = 0
              if $raw_file_with_original_case eq $raw_file_target_name;
        }

        $dedup_int++;

    } while ( $file_target_exists or $raw_target_exists );

    undef $targets{$file_target_name};
    undef $targets{$raw_file_target_name} if $has_raw_file;

    &dbg("   New name base: $new_name_base");
    &dbg("   Target:        $file_target_name");
    my $tmp = $raw_file_with_original_case // $raw_file;
    &dbg( "   Raw name:      $tmp",
        ( $has_raw_file ? ' (exists)' : ' (does not exist)' ) );
    if ($has_raw_file) {
        &dbg("   Raw target:    $raw_file_target_name");
    }

    push @rename_list, [ $file, $file_target_name ];
    if ($has_raw_file) {
        push @rename_list,
          [ $raw_file_with_original_case, $raw_file_target_name ];
    }
}

if ($opt_verbose) {
    print "When actual name is identical to target name, the line is [NOOP].\n";
    print "Verbose mode is active. NOOP lines are output.\n";
}

my $count = 0;
for my $elem (@rename_list) {
    my $s = $$elem[0];
    my $d = $$elem[1];

    my $do_rename = !( $s eq $d );
    $$elem[2] = $do_rename;

    ++$count if $do_rename;

    if ( $opt_verbose || $do_rename ) {
        print( ( $do_rename ? '' : '[NOOP] ' ), "$s -> $d\n" );
    }
}

&dbg('');

print "$count file(s) to rename.\n";

if ( !$opt_dry_run && !$opt_dont_ask_for_confirmation && $count >= 1 ) {
    print "Proceed to renaming? (y/N) ";
    my $response = <STDIN>;
    chomp $response;
    if ( lc($response) ne 'y' ) {
        print "Aborted.\n";
        exit 100;
    }
}

if ( !$opt_dry_run ) {
    for my $elem (@rename_list) {
        my $s         = $$elem[0];
        my $d         = $$elem[1];
        my $do_rename = $$elem[2];

        if ($do_rename) {
            print "$s -> $d\n";
            rename $s, $d;
        }
    }
}

