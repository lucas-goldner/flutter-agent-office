// The rooftop bar, wired into the office: going up there and back down, the bar and its drinks, the
// DJ's air horn, the glasses in people's hands, and how the drinks go to your head. The rooftop's
// part of main.ts, kept out of controller.dart, which only calls in here at a few spots.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/scene.dart';

import 'package:office_shared/protocol.dart';
import 'package:office_shared/rooftop.dart';

import '../audio/dnb_score.dart';
import '../audio/sound.dart';
import '../booze.dart';
import '../net/office_socket.dart' hide Profile;
import '../state/store.dart';
import '../ui/bar.dart';
import '../ui/hud_parts.dart' show HintPart;
import '../ui/modal.dart';
import '../world/character.dart';
import '../world/collider.dart';
import '../world/drunk.dart';
import '../world/hands.dart';
import '../world/labels.dart';
import '../world/office/office.dart';
import '../world/player.dart';
import '../world/rooftop.dart';
import '../world/toon.dart';
import 'roof_logic.dart';

/// Makes the city round the roof (world/city.dart), once it exists: the roof works without it.
typedef RoofCityMaker = RoofCity Function(NightParts night);

class RoofHub {
  RoofHub({
    required this.root,
    required this.office,
    required this.store,
    required this.net,
    required this.sound,
    required this.player,
    required this.me,
    required this.hands,
    required this.labels,
    required this.remote,
    required this.reach,
    this.city,
  });

  final Node root;
  final Office office;
  final Store store;
  final OfficeSocket net;
  final OfficeSound sound;
  final PlayerController player;
  final Person me;
  final Hands hands;
  final LabelHub labels;

  /// Someone else on the roof with you, by id.
  final Person? Function(String id) remote;

  /// Plays your reach, on your hands and your character, and shows it to everyone else.
  final VoidCallback reach;

  /// The city all around, far below.
  RoofCityMaker? city;

  /// Up on the roof: built the first time anyone goes up there.
  Rooftop? rooftop;

  /// Where you are now: up on the roof (true), or on a floor of the office.
  bool upTop = false;

  /// Drinks from the bar, and how they make the world look.
  final Booze booze = Booze();

  /// How the screen looks after a few (world/drunk.dart).
  final ValueNotifier<DrunkLook> look = ValueNotifier(DrunkLook.sober);

  /// How hard the strobes flash this frame (0–1), for the light.
  double strobe = 0;

  /// What someone else is holding, as their last `peer.act` said (the store keeps the rest of them).
  final Map<String, DrinkId?> _drinks = {};

  int _feeling = 0;
  double _nextHiccup = 0;
  double _nextSip = 0;
  double _lastHorn = -1e9;

  /// The drink in your hand everyone else was last told about.
  DrinkId? _shownDrink;
  final math.Random _rnd = math.Random();

  /// How far into the DJ's set it is, on the office's clock, so everyone up there hears the same bar.
  double djAt() => djTime(store.officeNow());

  static bool get _still => PlatformDispatcher.instance.accessibilityFeatures.disableAnimations;

  Rooftop theRoof() {
    var r = rooftop;
    if (r == null) {
      r = rooftop = buildRooftop(office.night, labels);
      r.group.visible = false;
      final make = city;
      if (make != null) r.setCity(make(office.night));
      root.add(r.group);
    }
    return r;
  }

  /// Up on the roof, or back down in the office: shows the one you're in, and walks, sounds and looks
  /// as it does there. Returns whether that changed.
  bool setPlace() {
    final up = store.floor == roof;
    if (up == upTop) return false;
    upTop = up;
    final r = up ? theRoof() : rooftop;
    office.group.visible = !up;
    r?.group.visible = up;
    if (up) r!.setFloors(math.max(1, store.floors.length));
    player.colliders = up ? r!.colliders : office.colliders;
    sound.setOutdoors(up);
    sound.setDj(up ? djAt : null);
    // Drinks stay at the bar (what you've had comes down with you).
    if (!up) booze.putDown();
    return true;
  }

  /// The elevator where you are: the office's, or the one up on the roof.
  Elevator lift() => upTop && rooftop != null ? rooftop!.elevator : office.elevator;

  /// What you can use up here (null: you're in the office, go by the office's lists).
  List<Interactable>? get usable => upTop && rooftop != null ? rooftop!.interactables : null;

  /// The line under someone's name while they're up here.
  String? whereabouts(PeerInfo p) => p.floor == roof ? roofWhereabouts(p.x, p.z) : null;

  /// The pools of light and the fog up here: the washes, the bar and the fire in place of the street
  /// lamps far below, no office lamplight under your feet, and the haze further off so the city shows.
  double get fogReach => upTop ? 3.4 : 1;

  void light(ToonLight l) {
    final r = rooftop;
    if (!upTop || r == null) return;
    l.officeLight.setZero();
    l.garageLight.setZero();
    for (var i = 0; i < l.lampPos.length; i++) {
      if (i < r.lamps.length) {
        final p = r.lamps[i];
        l.lampPos[i].setValues(p.x, p.y, p.z, p.reach);
        l.lampColor[i].setFrom(p.light);
      } else {
        l.lampPos[i].setZero();
      }
    }
    // Strobes flash the whole roof as a drop lands.
    l.ambient += strobe * 1.5 / math.pi;
    l.hemiIntensity += strobe * 0.8 / math.pi;
  }

  // ---- Messages ---------------------------------------------------------------------------------

  /// A message from the office that's about the roof.
  void onMessage(ServerMsg msg) {
    switch (msg) {
      case WelcomeMsg _:
        // The server forgot what's in your hand when it lost you.
        final d = _shownDrink;
        if (d != null) net.send(ActCmd(drink: d));
      case PeerActMsg m when m.drinkSet:
        // A drink from the rooftop bar in their hand, or put down.
        _drinks[m.id] = m.drink;
        final r = remote(m.id);
        if (m.drink != null) r?.reach();
        r?.holdDrink(m.drink?.drink);
      case HornMsg m:
        if (!upTop) break;
        sound.horn();
        if (m.by != store.profile.name) toast('📯 ${m.by} blew the air horn!');
      default:
        break;
    }
  }

  /// What [peer] is holding.
  Drink? drinkOf(PeerInfo peer) {
    final id = _drinks.containsKey(peer.id) ? _drinks[peer.id] : peer.drink;
    return id?.drink;
  }

  // ---- The bar and the DJ -----------------------------------------------------------------------

  double get _secs => nowMs() / 1000;

  /// E at the bar: the menu.
  void showBar() => openBar(cutOff: booze.cutOff(_secs), order: orderDrink);

  /// The bartender comes over and pours it (a water, if you've had enough), and slides it across to you.
  void orderDrink(Drink d) {
    final r = rooftop;
    if (r == null || !upTop) return;
    final cut = d.strength > 0 && booze.cutOff(_secs);
    final drink = cut ? DrinkId.water.drink : d;
    r.serve(player.pos.z);
    final at = r.pourAt;
    sound.pour(at.x, at.y, at.z);
    if (cut) toast("🙅 The bartender slides you a water instead: you've had enough", ToastKind.warn);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!upTop) return;
      booze.drink(drink, _secs);
      reach();
      if (player.view == ViewMode.first) hands.sip();
      if (!cut) toast('${drink.emoji} ${drink.name}. ${cheers[drink.id] ?? 'Enjoy!'}');
    });
  }

  /// E at the DJ booth: the air horn, for everyone on the roof.
  void blowHorn() {
    final now = nowMs();
    if (now - _lastHorn < 1500) return;
    _lastHorn = now;
    net.send(const HornCmd());
  }

  /// The bar's and the DJ booth's hints (null for anything else).
  (String, List<HintPart>)? hintFor(Interactable it) => switch (it.kind) {
    InteractKind.bar => barHint(booze.cutOff(_secs)),
    InteractKind.dj => djHint(djFrame(djAt())),
    _ => null,
  };

  /// E on something up here. True when it was the roof's.
  bool interact(Interactable it) {
    switch (it.kind) {
      case InteractKind.bar:
        showBar();
      case InteractKind.dj:
        blowHorn();
      default:
        return false;
    }
    return true;
  }

  // ---- Every frame -------------------------------------------------------------------------------

  /// How drunk you are, the glass in your hand, hiccups and the odd sip; and up on the roof,
  /// everything moving to the DJ's set. [now] on nowMs's clock, [t] the frame's seconds, [dark] how
  /// far the lamps are on.
  void tick(double now, double t, double dt, double dark) {
    final secs = now / 1000;
    final still = _still;
    final amount = booze.amount(secs);
    player.drunk = still ? 0 : math.min(1.3, amount);
    final glass = booze.holding(secs);
    me.holdDrink(glass);
    hands.holdDrink(glass);
    final id = glass?.id;
    if (id != _shownDrink) {
      _shownDrink = id;
      net.send(ActCmd(drink: id, drinkSet: true));
    }
    if (glass != null && player.view == ViewMode.first && now > _nextSip) {
      if (_nextSip > 0) hands.sip();
      _nextSip = now + 9000 + _rnd.nextDouble() * 9000;
    }
    final stage = booze.stage(secs);
    if (stage != _feeling) {
      if (stage > _feeling || stage == 0) toast(feelings[stage], stage >= 3 ? ToastKind.warn : ToastKind.info);
      _feeling = stage;
    }
    if (amount > 0.5 && now > _nextHiccup) {
      if (_nextHiccup > 0) sound.hiccup();
      _nextHiccup = now + 5000 + _rnd.nextDouble() * 12000;
    }
    look.value = DrunkLook.at(amount, t, motion: !still);

    final r = rooftop;
    strobe = upTop && r != null ? r.update(t, dt, djFrame(djAt()), RoofEnv(dark: dark, motion: !still)) : 0;
  }
}
