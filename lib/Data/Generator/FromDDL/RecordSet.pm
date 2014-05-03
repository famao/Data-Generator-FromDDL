package Data::Generator::FromDDL::RecordSet;
# Data::Generator::FromDDL::RecordSet is columnar-oriented storage.
# To output each generated record, it's needed to convert columns into rows.

use strict;
use warnings;
use List::Util qw(first);
use Compress::Zlib qw(compress uncompress);
use JSON ();
use YAML::Tiny ();
use bytes ();
use Class::Accessor::Lite (
    rw => [qw(table n cols)],
);

use Data::Generator::FromDDL::Util qw(need_quote_data_type);

sub new {
    my ($class, $table, $n) = @_;
    return bless {
        table => $table,
        n => $n,
        cols => [],
    }, $class;
}

sub store_column_values {
    my ($self, $field, $values) = @_;
    my $joined_values = join ',', @$values;
    my $compressed_values = compress($joined_values);
    push @{$self->{cols}}, {
        field => $field,
        compressed_values => $compressed_values,
    };
}

sub get_column_values {
    my ($self, $field_name) = @_;
    my $col = first { $_->{field}->name eq $field_name } @{$self->cols};
    if ($col) {
        my $uncompressed_values = uncompress($col->{compressed_values});
        return split ',', $uncompressed_values;
    } else {
        return undef;
    }
}

sub _construct_rows {
    my ($self, $with_quote) = @_;
    my $cols = $self->cols;
    my @rows;

    my %all_columns_values
        = map {
            my $field_name = $_->{field}->name;
            my @column_values = $self->get_column_values($field_name);
            $field_name => \@column_values
        } @$cols;

    for my $i (0..($self->n)-1) {
        my $row = [map { 
            my $field = $_->{field};
            my $values = $all_columns_values{$field->name};
            if ($with_quote && need_quote_data_type($field->data_type)) {
                "'" . $values->[$i] . "'";
            } else {
                $values->[$i];
            }
        } @$cols];
        push @rows, $row;
    }

    return @rows;
}

sub _construct_data {
    my $self = shift;
    my $cols = $self->cols;
    my @fields = map { $_->{field} } @$cols;
    my @rows = $self->_construct_rows;

    my $data = {
        table => $self->table->name,
        values => [],
    };
    for my $row (@rows) {
        my $record = {};
        for (0..$#fields) {
            $record->{$fields[$_]->name} = $row->[$_];
        }
        push @{$data->{values}}, $record;
    }
    return $data;
}

sub to_sql {
    my ($self, $pretty, $bytes_per_sql) = @_;
    my $cols = $self->cols;
    my @fields = map { $_->{field} } @$cols;
    my @rows = $self->_construct_rows(1);

    my $format;
    my $record_sep;
    if ($pretty) {
        $format = qq(
INSERT INTO
    `%s` (%s)
VALUES
    );
        $record_sep = ",\n    ";
    } else {
        $format = 'INSERT INTO `%s` (%s) VALUES ';
        $record_sep = ',';
    }
    my $columns = join ',', map { '`' . $_->name . '`' } @fields;
    my $insert_stmt = sprintf $format, $self->table->name, $columns;

    my $sqls = '';
    my @values;
    my $sum_bytes = bytes::length($insert_stmt) + 1; # +1 is for trailing semicolon of sql
    my $record_sep_len = bytes::length($record_sep);
    for my $row (@rows) {
        my $value = '(' . join(',', @$row) . ')';
        my $v_len = bytes::length($value);
        if ($sum_bytes + $v_len >= $bytes_per_sql) {
            if (@values) {
                $sqls .= $insert_stmt . (join $record_sep, @values) . ';';
                $sum_bytes = bytes::length($insert_stmt) + 1;
                @values = ();
            }
        }
        push @values, $value;
        $sum_bytes += $v_len + $record_sep_len;
    }

    if (@values) {
        $sqls .= $insert_stmt . (join $record_sep, @values) . ';';
    }
    return $sqls;
}

sub to_json {
    my ($self, $pretty) = @_;
    my $data = $self->_construct_data;
    if ($pretty) {
        return JSON->new->pretty->encode($data);
    } else {
        return JSON->new->encode($data);
    }
}

sub to_yaml {
    my ($self) = @_;
    my $data = $self->_construct_data;
    return YAML::Tiny::Dump($data);
}

1;
