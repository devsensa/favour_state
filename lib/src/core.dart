import 'dart:async';
import 'dart:developer';

import 'package:flutter/foundation.dart';

typedef ServiceProvider = T Function<T>({
  String instanceName,
  dynamic param1,
  dynamic param2,
});

typedef ReactionReducer<S, T> = T Function(S);

typedef ReactionEffect<S> = void Function(S);

typedef ReactionsNotifier = void Function<S extends Copyable>(S, Set<Symbol>);

typedef DerivedStoreFactory<SS extends StoreInitializer> = SS Function(
  S Function<S extends StoreInitializer>(),
);

typedef StoreActionEffect<T extends BaseStore<S>, S extends StoreState<S>>
    = FutureOr<void> Function(T, StateMutator, [ServiceProvider services]);

typedef AppStateBootstrap = void Function(AppState);

class StoreRuntime {
  final ServiceProvider services;

  StoreRuntime({this.services});

  final Map<Type, Map<Symbol, HashedObserverList<Reaction>>> _reactions = {};

  ValueReaction<S, T> valueReaction<S extends Copyable, T>(
    ReactionReducer<S, T> reducer, {
    Set<Symbol> topics,
  }) {
    final _topics = topics ?? {#self};
    final reaction = ValueReaction<S, T>(reducer: reducer, topics: _topics);
    _registerReaction<S>(reaction, _topics);
    return reaction;
  }

  EffectReaction<S> effectReaction<S extends Copyable>(
    ReactionEffect<S> effect, {
    Set<Symbol> topics,
  }) {
    final _topics = topics ?? {#self};
    final reaction = EffectReaction<S>(effect: effect, topics: _topics);
    _registerReaction<S>(reaction, _topics);
    return reaction;
  }

  void _registerReaction<S extends Copyable>(
    Reaction reaction,
    Set<Symbol> topics,
  ) {
    if (!_reactions.containsKey(S)) {
      _reactions[S] = {};
    }
    final reactionsForType = _reactions[S];

    if (!_states.containsKey(S)) {
      throw StateError('State of type $S not registered');
    }
    final state = _states.cast<Type, StateProvider>()[S].state;
    reaction._notify(state);

    void registerForTopic(Symbol topic) {
      if (!reactionsForType.containsKey(topic)) {
        reactionsForType[topic] = HashedObserverList();
      }
      reactionsForType[topic].add(reaction);
    }

    topics.forEach(registerForTopic);
  }

  void notifyReactions<S extends Copyable>(S state, Set<Symbol> topics) {
    if (!_reactions.containsKey(S)) {
      return;
    }

    final reactionsForType = _reactions[S];

    void notifyReaction(Reaction reaction) => reaction._notify(state);
    for (final topic in topics) {
      reactionsForType[topic]?.forEach((notifyReaction));
    }
  }

  void removeReaction() {}
  void removeAllReactions() {}

  final Map<Type, StateMutator> _states = {};
  StateProvider<S> state<S extends StoreState<S>>(S state) {
    if (_states.containsKey(S)) {
      throw StateError('StateController for type $S already registered');
    }
    final controller = StateController<S>(state, notifyReactions);
    _states[S] = controller;
    return controller;
  }

  FutureOr<void> run<SS extends BaseStore<S>, S extends StoreState<S>>(
    SS store,
    StoreAction<SS, S> action,
  ) async {
    final stateType = store.state.runtimeType;
    final mutator = _states[stateType];

    Timeline.startSync('${action.runtimeType}');
    await action(store, mutator, services);
    Timeline.finishSync();
  }
}

class AppState {
  final ServiceProvider serviceProvider;
  final AppStateBootstrap bootstrap;
  final StoreRuntime _runtime;
  final Map<Type, StoreInitializer> _stores = {};

  AppState({this.bootstrap, this.serviceProvider})
      : _runtime = StoreRuntime(services: serviceProvider) {
    if (bootstrap != null) {
      bootstrap(this);
    }
  }

  void registerStore<SS extends StoreInitializer>(SS store) {
    if (_stores.containsKey(SS)) {
      throw StateError('Store of type $SS already registered');
    }
    store.runtime = _runtime;
    _stores[SS] = store;
  }

  SS registerDerivedStore<SS extends StoreInitializer>(
    DerivedStoreFactory<SS> factory,
  ) {
    if (_stores.containsKey(SS)) {
      throw StateError('Store of type $SS already registered');
    }
    final derivedStore = factory(store);
    // ignore: cascade_invocations
    derivedStore.runtime = _runtime;
    _stores[SS] = derivedStore;
    return derivedStore;
  }

  SS store<SS extends StoreInitializer>() {
    if (!_stores.containsKey(SS)) {
      throw StateError('Store of type $SS not registered');
    }
    return _stores.cast<Type, SS>()[SS];
  }
}

abstract class StoreInitializer {
  // ignore: avoid_setters_without_getters
  set runtime(StoreRuntime runtime);
}

abstract class Reaction<S extends Copyable> {
  void _notify(S value);
}

class ValueReaction<S extends Copyable, T> extends ChangeNotifier
    implements Reaction<S>, ValueListenable<T> {
  final ReactionReducer<S, T> reducer;
  final Set<Symbol> topics;
  T _value;

  ValueReaction({
    @required this.reducer,
    @required this.topics,
  })  : assert(reducer != null, 'reducer is null'),
        assert(topics != null, 'topics is null');

  @override
  T get value => _value;

  @override
  void _notify(S value) {
    final newValue = reducer(value);
    if (newValue != _value) {
      _value = newValue;
      notifyListeners();
    }
  }
}

class EffectReaction<S extends Copyable> extends Reaction<S> {
  final ReactionEffect<S> effect;
  final Set<Symbol> topics;

  EffectReaction({
    @required this.effect,
    @required this.topics,
  })  : assert(effect != null, 'reducer is null'),
        assert(topics != null, 'topics is null');

  @override
  void _notify(S value) {
    effect(value);
  }
}

abstract class Copyable {
  Copyable copyWith();
}

abstract class StateMutator {
  void merge(Map<Symbol, Object> changes);
  void set(Symbol topic, Object value);
  void operator []=(Symbol topic, Object value);
  // ignore: avoid_setters_without_getters
  set changes(Map<Symbol, Object> newChanges);
}

abstract class StoreState<S extends StoreState<S>> extends Copyable {
  @override
  S copyWith();
}

abstract class StateProvider<S extends StoreState<S>> {
  S get state;
}

class StateController<S extends StoreState<S>> extends StateMutator
    implements StateProvider<S> {
  S _state;
  final ReactionsNotifier _notifier;

  StateController(
    S state,
    void Function<S extends Copyable>(S, Set<Symbol>) notifier,
  )   : assert(state != null, 'state is null'),
        assert(notifier != null, 'notifier is null'),
        _state = state,
        _notifier = notifier;

  @override
  void operator []=(Symbol topic, Object value) {
    _merge({topic: value});
  }

  @override
  // ignore: avoid_setters_without_getters
  set changes(Map<Symbol, Object> changes) {
    _merge(changes);
  }

  @override
  void merge(Map<Symbol, Object> changes) {
    _merge(changes);
  }

  @override
  void set(Symbol topic, Object value) {
    _merge({topic: value});
  }

  @override
  S get state => _state;

  void _merge(Map<Symbol, Object> changes) {
    Timeline.startSync('Mutate ${S}');
    final dynamic newState = Function.apply(
      _state.copyWith,
      null,
      changes,
    );
    Timeline.finishSync();
    if (newState is S) {
      _state = newState;
      Timeline.startSync('Notify $S changed');
      _notifier<S>(newState, {#self, ...changes.keys});
      Timeline.finishSync();
      return;
    }
    throw StateError('state method "copyWith" return instance of unknown type');
  }
}

// Marker interface
abstract class Store {}

abstract class BaseStore<S extends StoreState<S>>
    implements StoreInitializer, StateProvider<S>, Store {
  StoreRuntime _runtime;
  StateProvider<S> _stateProvider;

  @override
  S get state => _stateProvider.state;

  @override
  // ignore: avoid_setters_without_getters
  set runtime(StoreRuntime runtime) {
    if (_runtime != null) {
      throw StateError('StoreRuntime already setup');
    }
    _runtime = runtime;
    _init();
  }

  void _init() {
    _stateProvider = _runtime.state<S>(initState());
    initReactions();
  }

  S initState();
  void initReactions();

  ValueReaction<S, T> valueReaction<T>(
    ReactionReducer<S, T> reducer, {
    Set<Symbol> topics,
  }) =>
      _runtime.valueReaction<S, T>(reducer, topics: topics);

  EffectReaction<SS> effectReaction<SS extends StoreState<SS>>(
    ReactionEffect<SS> effect, {
    Set<Symbol> topics,
  }) =>
      _runtime.effectReaction<SS>(effect, topics: topics);

  Future<void> run<SS extends BaseStore<S>>(StoreAction<SS, S> action) async {
    await _runtime.run(this, action);
  }
}

class StoreAction<T extends BaseStore<S>, S extends StoreState<S>> {
  final StoreActionEffect<T, S> effect;

  StoreAction(this.effect) : assert(effect != null, 'effect is null');

  FutureOr<void> call(
    T store,
    StateMutator mutator, [
    ServiceProvider services,
  ]) {
    effect(store, mutator, services);
  }
}