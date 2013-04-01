package Class::StateMachine::Declarative::Builder;

use strict;
use warnings;
use Carp;
use 5.010;
use Scalar::Util ();

use Class::StateMachine;
*debug = \$Class::StateMachine::debug;
our $debug;

sub _debug {
    my $n = shift;
    warn "@_\n" if $debug and $n;
}


sub new {
    my ($class, $target_class) = @_;
    my $top = Class::StateMachine::Declarative::Builder::State->_new;
    my $self = { top => $top,
                 states => { '/' => $top },
                 class => $target_class };
    bless $self, $class;
    $self;
}

sub _bad_def {
    my ($self, $state, @msg) = @_;
    croak "@msg on definition of state '$state->{name}' for class '$self->{class}'";
}

sub _ref_to_pair_list {
    my $ref = shift;
    my @l;
    do {
        local ($@, $SIG{__DIE__});
        eval { @l = @$ref; 1 } or eval { @l = %$ref; 1 }
    } or croak "ARRAY or HASH ref expected";
    @l & 1 and croak "odd number of elements in list";
    @l;
}

sub _ref_is_ordered_list {
    my $ref = shift;
    local ($@, $SIG{__DIE});
    eval { @$ref || 1 };
}


sub _ensure_list {
    my $ref = shift;
    ( UNIVERSAL::isa($ref, 'ARRAY') ? @$ref : $ref );
}

sub parse_state_declarations {
    my $self = shift;
    $self->_parse_state_declarations($self->{top}, @_);
    $self->_resolve_transitions($self->{top}, []);
}

sub _parse_state_declarations {
    my $self = shift;
    my $parent = shift;
    while (@_) {
        my $name = shift;
        my $decl = shift // {};
        $self->_add_state($name, $parent, _ref_to_pair_list($decl));
    }
}

sub _add_state {
    my ($self, $name, $parent, @decl) = @_;

    my $state = Class::StateMachine::Declarative::Builder::State->_new($name, $parent);

    while (@decl) {
        my $k = shift @decl;
        my $method = $self->can("_handle_attr_$k") or $self->_bad_def($state, "bad declaration '$k'");
        if (defined (my $v = shift @decl)) {
            _debug(16, "calling handler for attribute $k with value $v");
            $method->($self, $state, $v);
        }
    }
    $self->{states}{$state->{full_name}} = $state;
    $state;
}

sub _handle_attr_enter {
    my ($self, $state, $v) = @_;
    $state->{enter} = $v;
}

sub _handle_attr_leave {
    my ($self, $state, $v) = @_;
    $state->{leave} = $v;
}

sub _handle_attr_jump {
    my ($self, $state, $v) = @_;
    $state->{jump} = $v;
}


sub _handle_attr_delay {
    my ($self, $state, $v) = @_;
    push @{$state->{delay}}, _ensure_list($v);
}

sub _handle_attr_ignore {
    my ($self, $state, $v) = @_;
    push @{$state->{ignore}}, _ensure_list($v);
}

sub _handle_attr_transitions {
    my ($self, $state, $v) = @_;
    my @transitions = _ref_to_pair_list($v);
    while (@transitions) {
        my $event = shift @transitions;
        my $target = shift @transitions;
        $state->{transitions}{$event} = $target if defined $target;
    }
}

sub _handle_attr_substates {
    my ($self, $state, $v) = @_;
    $self->_parse_state_declarations($state, _ref_to_pair_list($v));
    if (_ref_is_ordered_list($v)) {
        $state->{substates_are_ordered} = 1;
    }
}

sub _resolve_transitions {
    my ($self, $state, $path) = @_;
    my @path = (@$path, $state->{name});
    my %transitions_abs;
    my %transitions_rev;
    while (my ($event, $target) = each %{$state->{transitions}}) {
        my $target_abs = $self->_resolve_target($target, \@path);
        $transitions_abs{$event} = $target_abs;
        push @{$transitions_rev{$target_abs} ||= []}, $event;
    }
    $state->{transitions_abs} = \%transitions_abs;
    $state->{transitions_rev} = \%transitions_rev;

    for my $substate (@{$state->{substates}}) {
        $self->_resolve_transitions($substate, \@path);
    }
}

sub _resolve_target {
    my ($self, $target, $path) = @_;
    # _debug(32, "resolving target '$target' from '".join('/',@$path)."'");
    if ($target =~ m|^__(\w+)__$|) {
        return $target;
    }
    if ($target =~ m|^/|) {
        return $target if $self->{states}{$target};
        _debug(32, "absolute target '$target' not found");
    }
    else {
        my @path = @$path;
        while (@path) {
            my $target_abs = join('/', @path, $target);
            if ($self->{states}{$target_abs}) {
                _debug(32, "target '$target' from '".join('/',@$path)."' resolved as '$target_abs'");
                return $target_abs;
            }
            pop @path;
        }
    }

    my $name = join('/', @$path);
    $name =~ s|^/+||;
    croak "unable to resolve transition target '$target' from state '$name'";
}

my $ignore_cb = sub {};
my $goto_next_state = sub { $_[0]->state($_[0]->next_state) };

sub generate_class {
    my $self = shift;
    my $class = $self->{class};
    while (my ($full_name, $state) = each %{$self->{states}}) {
        my $name = $state->{name};
        my $parent = $state->{parent};
        if ($parent and $parent != $self->{top}) {
            Class::StateMachine::set_state_isa($class, $state, $parent->{name});
        }

        for my $when ('enter', 'leave') {
            my $action = $state->{$when};
            Class::StateMachine::install_method($class,
                                                "${when}_state",
                                                sub { shift->$action },
                                                $name);
        }
        for my $delay (@{$state->{delay}}) {
            my $event = $delay;
            Class::StateMachine::install_method($class,
                                                $event,
                                                sub { shift->delay_until_next_state($event) },
                                                $name);
        }
        for my $ignore (@{$state->{delay}}) {
            Class::StateMachine::install_method($class, $ignore, $ignore_cb, $name);
        }

        while (my ($target, $events) = each %{$state->{transitions_rev}}) {
            my $method;
            if ($target eq '__next__') {
                $method = $goto_next_state;
            }
            else {
                my $target_state = $self->{states}{$target};
                $method = $target_state->{come_here_method} //= do {
                    my $target_name = $target_state->{name};
                    sub { shift->state($target_name) }
                };
            }
            Class::StateMachine::install_method($class, $_, $method, $name) for @$events;
        }

        my @ss = @{$state->{substates}};
        if ($state->{substates_are_ordered}) {
            my $current = shift @ss;
            while (defined(my $next = shift @ss)) {
                my $next_state = $next->{name};
                Class::StateMachine::install_method($class, 'next_state', sub { $next_state }, $current->{name});
                $current = $next_state;
            }
        }
        else {
            for my $ss (@ss) {
                my $state_name = $ss->{name};
                Class::StateMachine::install_method($class, 'next_state',
                                                    sub { croak "next state not defined in state '$state_name'" },
                                                    $ss->{name});
            }
        }
    }
}

package Class::StateMachine::Declarative::Builder::State;

sub _new {
    my ($class, $name, $parent) = @_;
    my $full_name = ($parent ? "$parent->{full_name}/$name" : $name // "");
    my $final_name = $full_name;
    $final_name =~ s|^/+||;
    my $state = { short_name => $name,
                  full_name => $full_name,
                  name => $final_name,
                  parent => $parent,
                  substates => [],
                  transitions => {},
                  ignore => [],
                  delay => [] };
    bless $state, $class;
    push @{$parent->{substates}}, $state if $parent;
    Scalar::Util::weaken($state->{parent});
    $state;
}

1;
