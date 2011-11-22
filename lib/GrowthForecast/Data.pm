package GrowthForecast::Data;

use strict;
use warnings;
use utf8;
use DBIx::Sunny;
use Time::Piece;
use Digest::MD5 qw/md5_hex/;
use List::Util;
use Encode;
use Log::Minimal;

sub new {
    my $class = shift;
    my $root_dir = shift;
    bless { root_dir => $root_dir }, $class;
}

my $_on_connect = sub {
    my $dbh = shift;
    $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS graphs (
    service_name VARCHAR(255) NOT NULL,
    section_name VARCHAR(255) NOT NULL,
    graph_name   VARCHAR(255) NOT NULL,
    number       INT NOT NULL DEFAULT 0,
    description  VARCHAR(255) NOT NULL DEFAULT '',
    sort         UNSIGNED INT NOT NULL DEFAULT 0,
    gmode        VARCHAR(255) NOT NULL DEFAULT 'gauge',
    color        VARCHAR(255) NOT NULL DEFAULT '#00CC00',
    ulimit       INT NOT NULL DEFAULT 1000000000,
    llimit       INT NOT NULL DEFAULT 0,
    sulimit       INT NOT NULL DEFAULT 100000,
    sllimit       INT NOT NULL DEFAULT 0,
    type         VARCHAR(255) NOT NULL DEFAULT 'AREA',
    stype         VARCHAR(255) NOT NULL DEFAULT 'AREA',
    created_at   UNSIGNED INT NOT NULL,
    updated_at   UNSIGNED INT NOT NULL,
    PRIMARY KEY  (service_name, section_name, graph_name)
)
EOF

    $dbh->do(<<EOF);
CREATE TABLE IF NOT EXISTS prev_graphs (
    service_name VARCHAR(255) NOT NULL,
    section_name VARCHAR(255) NOT NULL,
    graph_name   VARCHAR(255) NOT NULL,
    number       INT NOT NULL DEFAULT 0,
    subtract     INT,
    updated_at   UNSIGNED INT NOT NULL,
    PRIMARY KEY  (service_name, section_name, graph_name)
)
EOF
    return;
};

sub dbh {
    my $self = shift;
    $self->{dbh} ||= DBIx::Sunny->connect_cached('dbi:SQLite:dbname='.$self->{root_dir}.'/data/gforecast.db','','',{
        Callbacks => {
            connected => $_on_connect,
        },        
    });
    $self->{dbh};
}

sub get {
    my ($self, $service, $section, $graph) = @_;
    my $row = $self->dbh->select_row(
        'SELECT * FROM graphs WHERE service_name = ? AND section_name = ? AND graph_name = ?',
        $service, $section, $graph
    );
    return unless $row;
    $row->{created_at} = localtime($row->{created_at})->strftime('%Y/%m/%d %T');
    $row->{updated_at} = localtime($row->{updated_at})->strftime('%Y/%m/%d %T');
    $row->{md5} = md5_hex( join(':',map { Encode::encode_utf8($_) } $row->{service_name},$row->{section_name},$row->{graph_name}) );
    $row;
}

sub get_for_rrdupdate {
    my ($self, $service, $section, $graph) = @_;
    my $dbh = $self->dbh;

    my $data = $dbh->select_row(
        'SELECT * FROM graphs WHERE service_name = ? AND section_name = ? AND graph_name = ?',
        $service, $section, $graph
    );
    return if !$data;

    $dbh->begin_work;
    my $prev = $dbh->select_row(
        'SELECT * FROM prev_graphs WHERE service_name = ? AND section_name = ? AND graph_name = ?',
        $service, $section, $graph
    );

    my $subtract;
    if ( !$prev ) {
        $subtract = 'U';
        $dbh->query(
            'INSERT INTO prev_graphs (service_name, section_name, graph_name, number, subtract, updated_at) 
                         VALUES (?,?,?,?,?,?)',
            $service, $section, $graph, $data->{number}, undef, $data->{updated_at});

    }
    elsif ( $data->{updated_at} != $prev->{updated_at} ) {
        $subtract = $data->{number} - $prev->{number};
        $dbh->query(
            'UPDATE prev_graphs SET number=?, subtract=?, updated_at=? WHERE service_name = ? AND section_name = ? AND graph_name = ?',
            $data->{number}, $subtract, $data->{updated_at},
            $service, $section, $graph,
        );        
    }
    else {
        $subtract = $prev->{subtract};
        $subtract = 'U' if ! defined $subtract;
    }

    $dbh->commit;
    $data->{created_at} = localtime($data->{created_at})->strftime('%Y/%m/%d %T');
    $data->{updated_at} = localtime($data->{updated_at})->strftime('%Y/%m/%d %T');
    $data->{md5} = md5_hex( join(':',map { Encode::encode_utf8($_) } $data->{service_name},$data->{section_name},$data->{graph_name}) );
    $data->{subtract} = $subtract;
    $data;
}

sub update {
    my ($self, $service, $section, $graph, $number, $mode ) = @_;
    my $dbh = $self->dbh;
    $dbh->begin_work;

    my $data = $self->get($service, $section, $graph);
    if ( defined $data ) {
        if ( $mode eq 'count' ) {
            $number += $data->{number};
        }
        $dbh->query(
            'UPDATE graphs SET number=?, updated_at=? WHERE service_name = ? AND section_name = ? AND graph_name = ?',
            $number, time,
            $service, $section, $graph,
        );
    }
    else {
        my @colors = List::Util::shuffle(qw/33 66 99 cc/);
        my $color = '#' . join('', splice(@colors,0,3));
        $dbh->query(
            'INSERT INTO graphs (service_name, section_name, graph_name, number, description, color, created_at, updated_at) 
                         VALUES (?,?,?,?,?,?,?,?)',
            $service, $section, $graph, $number, "", $color, time, time
        ); 
    }
    my $row = $self->get($service, $section, $graph);
    $dbh->commit;

    $row;
}

sub update_graph {
    my ($self, $service, $section, $graph, $description, $sort, $gmode, $color, $type, $stype, $llimit, $ulimit, $sllimit, $sulimit ) = @_;
    my $dbh = $self->dbh;
    $dbh->query(
        'UPDATE graphs SET description=?, sort=?, gmode=?, color=?, type=?, stype=?, llimit=?, ulimit=?, sllimit=?, sulimit=?
          WHERE service_name = ? AND section_name = ? AND graph_name = ?',
            $description, $sort, $gmode, $color, $type, $stype, $llimit, $ulimit, $sllimit, $sulimit,
            $service, $section, $graph,
    );
    return 1;
}

sub get_services {
    my $self = shift;
    my $rows = $self->dbh->select_all(
        'SELECT DISTINCT service_name FROM graphs',
    );
    my @names = map { $_->{service_name} } @$rows;
    \@names
}

sub get_sections {
    my $self = shift;
    my $service_name = shift;
    my $rows = $self->dbh->select_all(
        'SELECT DISTINCT section_name FROM graphs WHERE service_name = ?',
        $service_name,
    );
    my @names = map { $_->{section_name} } @$rows;
    \@names;
} 

sub get_graphs {
   my $self = shift;
   my ($service_name, $section_name) = @_;
   my $rows = $self->dbh->select_all(
       'SELECT * FROM graphs WHERE service_name = ? AND section_name = ? ORDER BY sort DESC',
       $service_name, $section_name
   );
   my @ret;
   for my $row ( @$rows ) {
       $row->{created_at} = localtime($row->{created_at})->strftime('%Y/%m/%d %T');
       $row->{updated_at} = localtime($row->{updated_at})->strftime('%Y/%m/%d %T');
       $row->{md5} = md5_hex( join(':', map { Encode::encode_utf8($_) } $row->{service_name},$row->{section_name},$row->{graph_name}) );
       push @ret, $row; 
   }
   \@ret;
}

sub get_all_graphs {
   my $self = shift;
   $self->dbh->select_all(
       'SELECT service_name, section_name, graph_name FROM graphs',
   );
}

sub remove {
    my ($self, $service, $section, $graph ) = @_;
    my $dbh = $self->dbh;
    $dbh->query(
        'DELETE FROM graphs WHERE service_name = ? AND section_name = ? AND graph_name = ?',
        $service, $section, $graph
    );
    $dbh->query(
        'DELETE FROM prev_graphs WHERE service_name = ? AND section_name = ? AND graph_name = ?',
        $service, $section, $graph
    );

}

1;

