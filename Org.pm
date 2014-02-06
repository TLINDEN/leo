#
# Copyleft (l) 2000-2014 by Thomas Linden <tom@daemon.de>. leo may be
# used and distributed under the terms of the GNU General Public License.
# All other brand and product names are trademarks, registered trademarks
# or service marks of their respective holders.

package WWW::Dict::Leo::Org;
$WWW::Dict::Leo::Org::VERSION = 1.37;

use strict;
use warnings;
use English '-no_match_vars';
use Carp::Heavy;
use Carp;
use IO::Socket;
use MIME::Base64;
use HTML::TableParser;

sub debug;

sub new {
  my ($class, %param) = @_;
  my $type = ref( $class ) || $class;

  my %settings = (
    "-Host" => "pda.leo.org",
    "-Port" => 80,
    "-UserAgent" => "Mozilla/5.0 (Windows; U; Windows NT 5.1; de; rv:1.8.1.9) Gecko/20071025 Firefox/2.0.0.9",
    "-Proxy" => "",
    "-ProxyUser" => "",
    "-ProxyPass" => "",
    "-Debug" => 0,
    "-SpellTolerance" => "standard",  # on, off
    "-Morphology" => "standard",      # none, forcedAll
    "-CharTolerance" => "relaxed",    # fuzzy, exact
    "-Language" => "en",           # en2de, de2fr, fr2de, de2es, es2de

    "data" => {}, # the results
    "section" => [],
    "title" => "",
    "segments" => [],
    "Maxsize" => 0,
    "Linecount" => 0,
  );

  foreach my $key (keys %param) {
    $settings{$key} = $param{$key}; # override defaults
  }

  my $self = \%settings;
  bless $self, $type;

  return $self;
}

sub translate {
  my($this, $term) = @_;

  my $linecount = 0;
  my $maxsize   = 0;
  my @match     = ();

  #
  # form var transitions for searchLoc
  #
  my %lang = (
	      de2en => 1,
	      en2de => -1,
	      de2fr => 1,
	      fr2de => -1,
              es2de => -1,
              de2es => 1,
              es    => 0,
	      en    => 0,
	      fr    => 0,
	      speak => "ende"
	     );

  if ($this->{"-Language"}) {
    if ($this->{"-Language"} =~ /fr/) {
      # used for francaise translation
      $lang{speak} = "frde";
    }
    elsif ($this->{"-Language"} =~ /es/) {
      $lang{speak} = "esde";
    }
    if (exists $lang{$this->{"-Language"}}) {
      $this->{"-Language"} = $lang{$this->{"-Language"}};
    }
    else {
      croak "Unsupported language: " . $this->{"-Language"};
    }
  }

  #
  # cut invalid values for parameters or set defaults if unspecified
  #
  my %form = (
	      spellToler => { mask => [ qw(standard on off) ],         val => $this->{"-SpellTolerance"} || "standard" },
	      deStem     => { mask => [ qw(standard none forcedAll) ], val => $this->{"-Morphology"}     || "standard" },
	      cmpType    => { mask => [ qw(fuzzy exact relaxed) ],     val => $this->{"-CharTolerance"}  || "relaxed"  },
	      searchLoc  => { mask => [ qw(-1 0 1) ],                  val => $this->{"-Language"}       || "0"        },
	      );
  my @form;
  foreach my $var (keys %form) {
    if (grep { $form{$var}->{val} eq $_ } @{$form{$var}->{mask}}) {
      push @form, $var . "=" . $form{$var}->{val};
    }
  }

  # add language
  push @form, "lp=$lang{speak}";

  #
  # process whitespaces
  #
  my $query = $term;
  $query =~ s/\s\s*/ /g;
  $query =~ s/\s/\+/g;
  push @form, "search=$query";

  #
  # make the query cgi'ish
  #
  my $form = join "&", @form;

  # store for result caching
  $this->{Form} = $form;

  #
  # check for proxy settings and use it if exists
  # otherwise use direct connection
  #
  my ($url, $site);
  my $ip = $this->{"-Host"};
  my $port = $this->{"-Port"};
  my $proxy_user = $this->{"-ProxyUser"};
  my $proxy_pass = $this->{"-ProxyPass"};

  if ($this->{"-Proxy"}) {
    my $proxy = $this->{"-Proxy"};
    $proxy =~  s/^http:\/\///i;
    if ($proxy =~ /^(.+):(.+)\@(.*)$/) {
      # proxy user account
      $proxy_user = $1;
      $proxy_pass = $2;
      $proxy      = $3;
      $this->debug( "proxy_user: $proxy_user");
    }
    my($host, $pport) = split /:/, $proxy;
    if ($pport) {
      $url = "http://$ip:$port/dictQuery/m-vocab/$lang{speak}/de.html";
      $port = $pport;
    }
    else {
      $port = 80;
    }
    $ip = $host;
    $this->debug( "connecting to proxy:", $ip, $port);
  }
  else {
    $this->debug( "connecting to site:", $ip, "port", $port);
    $url = "/dictQuery/m-vocab/$lang{speak}/de.html";
  }

  my $conn = new IO::Socket::INET(
				  Proto    => "tcp",
				  PeerAddr => $ip,
				  PeerPort => $port,
				 ) or die "Unable to connect to $ip:$port: $!\n";
  $conn->autoflush(1);

  $this->debug( "GET $url?$form HTTP/1.0");
  print $conn "GET $url?$form HTTP/1.0\r\n";

  # be nice, simulate Konqueror.
  print $conn 
    qq($this->{"-UserAgent"}
Host: $this->{"-Host"}:$this->{"-Port"}
Accept: text/*;q=1.0, image/png;q=1.0, image/jpeg;q=1.0, image/gif;q=1.0, image/*;q=0.8, */*;q=0.5
Accept-Charset: iso-8859-1;q=1.0, *;q=0.9, utf-8;q=0.8
Accept-Language: en_US, en\r\n);

  if ($this->{"-Proxy"} and $proxy_user) {
    # authenticate
    # construct the auth header
    my $coded = encode_base64("$proxy_user:$proxy_pass");
    $this->debug( "Proxy-Authorization: Basic $coded");
    print $conn "Proxy-Authorization: Basic $coded\r\n";
  }

  # finish the request
  print $conn "\r\n";

  #
  # parse dict.leo.org output
  #
  my @line = <$conn>;
  close $conn or die "Connection failed: $!\n";
  $this->debug( "connection: done");

  $site = join "", @line;

  if ($site !~ /HTTP\/1\.(0|1) 200 OK/i) {
    if ($site =~ /HTTP\/1\.(0|1) (\d+) /i) {
      # got HTTP error
      my $err = $2;
      if ($err == 407) {
	croak "proxy auth required or access denied!\n";
      }
      else {
	croak "got HTTP error $err!\n";
      }
    }
  }

  if ($site =~ /produced\s+no\s+results\s+for\s+the\s+selected/
      || $site =~ /Die\s+Suche\s+nach.*lieferte\skeine/) {
    return ();
  }

  #$site =~ s/(<table[^>]*>)/\n$1\n/g;
  #$site =~ s/(<\/table[^>]*>)/\n$1\n/g;
  #print $site;

  my @request = ({
		  id  => 3,
		  row => sub { $this->row(@_); }
		  }
		 );
  $this->{Linecount} = 1;
  my $p = HTML::TableParser->new( \@request,
				  { Decode => 1, Trim => 1, Chomp => 1, DecodeNBSP => 1 } );
  $site=~s/&#160;/\&nbsp\;/g;
  $p->parse($site);

  # put the rest on the stack, if any
  if (@{$this->{section}}) {
    $this->{data}->{ $this->{title} } = $this->{section};
    push @{$this->{segments}}, $this->{title};
  }

  # put back in order
  my @matches;
  foreach my $title (@{$this->{segments}}) {
    push @matches, { title => $title, data => $this->{data}->{$title} };
  }


  return @matches;
}


sub row {
  #
  # divide rows into titles and lang data.
  # rows with the last one of 5 defined and
  # where the last and the pre-last are qual
  # are titles.
  my ( $this, $tbl_id, $line_no, $data, $udata ) = @_;

  if ($data->[1] && $data->[0] eq $data->[1]) {
    $this->debug("Probable start of a new section: $data->[1]");
    if (@{$this->{section}}) {
      $this->{data}->{ $this->{title} } = $this->{section};
      push @{$this->{segments}}, $this->{title};
    }

    $this->{title} = $data->[1];
    $this->{section} = [];
  }
  else {
    if (length($data->[0]) > $this->{Maxsize}) {
      $this->{Maxsize} = length($data->[0]);
    }
    $this->debug("line: $line_no, left:  $data->[0], right: $data->[1]");
    push @{$this->{section}}, { left => $data->[0], right => $data->[1] };
    $this->{Linecount}++;
  }
}


sub maxsize {
  my($this) = @_;
  return $this->{Maxsize};
}

sub lines {
  my($this) = @_;
  return $this->{Linecount};
}

sub form {
  my($this) = @_;
  return $this->{Form};
}

sub debug {
  my($this, $msg) = @_;
  if ($this->{"-Debug"}) {
    print STDERR "%DEBUG: $msg\n";
  }
}


1;

=head1 NAME

WWW::Dict::Leo::Org - Interface module to dictionary dict.leo.org

=head1 SYNOPSIS

 use WWW::Dict::Leo::Org;
 my $leo = new WWW::Dict::Leo::Org();
 my @matches = $leo->translate($term);

=head1 DESCRIPTION

B<WWW::Dict::Leo::Org> is a module which connects to the website
B<dict.leo.org> and translates the given term. It returns an array
of hashes. Each hash contains a left side and a right side of the
result entry.

=head1 OPTIONS

B<new()> has several parameters, which can be supplied as a hash.

All parameters are optional.

=over

=item I<-Host>

The hostname of the dict website to use. For the moment only dict.leo.org
is supported, which is also the default - therefore changing the
hostname would not make much sense.

=item I<-Port>

The tcp port to use for connecting, the default is 80, you shouldn't
change it.

=item I<-UserAgent>

The user-agent to send to dict.leo.org site. Currently this is the
default:

 Mozilla/5.0 (Windows; U; Windows NT 5.1; de; rv:1.8.1.9) Gecko/20071025 Firefox/2.0.0.9

=item I<-Proxy>

Fully qualified proxy server. Specify as you would do in the well
known environment variable B<http_proxy>, example:

 -Proxy => "http://192.168.1.1:3128"

=item I<-ProxyUser> I<-ProxyPass>

If your proxy requires authentication, use these parameters
to specify the credentials.

=item I<-Debug>

If enabled (set to 1), prints a lot of debug information to
stderr, normally only required for developers or to
report bugs (see below).

=back

Parameters to control behavior of dict.leo.org:

=over

=item I<-SpellTolerance>

Be tolerant to spelling errors.

Default: turned on.

Possible values: on, off.

=item I<-Morphology>

Provide morphology information.

Default: standard.

Possible values: standard, none, forcedAll.

=item I<-CharTolerance>

Allow umlaut alternatives.

Default: relaxed.

Possible values: fuzzy, exact, relaxed.

=item I<-Language>

Translation direction. Please note that dict.leo.org always translates
either to or from german. The following values can be used:

=over

=item de

Alias for B<de2en> - german to english.

=item fr

Alias for B<de2fr> - german to french.

=item es

Alias for B<de2es> - german to espaniol.

=item en2de

english to german.

=item fr2de

french to german.

=item es2de

espaniol to german.

=back

=back

=head1 METHODS

=head2 translate($term)

Use this method after initialization to connect to dict.leo.org
and translate the given term. It returns an array of hashes containing
the actual results.

 use WWW::Dict::Leo::Org;
 use Data::Dumper;
 my $leo = new WWW::Dict::Leo::Org();
 my @matches = $leo->translate("test");
 print Dumper(\@matches);

which prints:

 $VAR1 = [
          {
            'data' => [
                        {
                          'left' => 'check',
                          'right' => 'der Test'
                        },
                        {
                          'left' => 'quiz (Amer.)',
                          'right' => 'der Test    [Schule]'
                      ],
            'title' => 'Unmittelbare Treffer'
          },
          {
            'data' => [
                        {
                          'left' => 'to fail a test',
                          'right' => 'einen Test nicht bestehen'
                        },
                        {
                          'left' => 'to test',
                          'right' => 'Tests macheneinen Test machen'
                        }
                      ],
            'title' => 'Verben und Verbzusammensetzungen'
          },
            'data' => [
                        {
                          'left' => 'testing  adj.',
                          'right' => 'im Test'
                        }
                      ],
            'title' => 'Wendungen und Ausdrücke'
          }
        ];


You might take a look at the B<leo> script how to process
this data.

=head2 maxsize()

Returns the size of the largest returned term (left side).

=head2 lines()

Returns the number of translation results.

=head2 form()

Returns the submitted form uri.

=head1 SEE ALSO

L<leo>

=head1 COPYRIGHT

WWW::Dict::Leo::Org -
Copyright (c) 2007-2014 by Thomas Linden

L<http://dict.leo.org/> -
Copyright (c) 1995-2014 LEO Dictionary Team.

=head1 AUTHOR

Thomas Linden <tlinden@cpan.org>

=head1 HOW TO REPORT BUGS

Use L<rt.cpan.org> to report bugs, select the queue for B<WWW::Dict::Leo::Org>.

Please don't forget to add debugging output!

=head1 VERSION

1.35

=cut
