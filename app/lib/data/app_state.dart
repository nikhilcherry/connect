import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n.dart';
import '../services/notifications.dart';
import '../services/rc_mock.dart';
import '../services/whisper.dart';
import 'models.dart';

/// Single source of truth for the signed-in owner. v1 supports one vehicle
/// per account in the UI, though the schema allows several.
class AppState extends ChangeNotifier {
  AppState(this._db);

  final SupabaseClient _db;
  final Map<String, RealtimeChannel> _channels = {};

  bool loading = true;
  String? loadError;

  /// True when [loadError] is a connectivity problem rather than the server
  /// refusing us. The two need different screens: "Offline" for a server-side
  /// fault sends people checking their Wi-Fi for nothing.
  bool loadErrorIsNetwork = false;

  /// True while the screen shows what was saved on this phone because the
  /// server could not be reached. Everything that lives on the phone keeps
  /// working; anything that needs the server fails with the usual message.
  bool offline = false;
  Vehicle? vehicle;

  /// Every car this user owns or shares; [vehicle] is the one on screen.
  List<Vehicle> vehicles = [];
  Tag? tag;
  List<CarAlert> alerts = [];
  List<EmergencyContact> contacts = [];
  List<FamilyMember> family = [];
  List<Society> societies = [];

  /// Newest first, across every society the user is in.
  List<SocietyNotice> notices = [];

  String? get userId => _db.auth.currentUser?.id;

  /// False for a family member using a car someone else added.
  bool get isOwner => vehicle == null || vehicle!.owner == userId;

  int get openAlerts => alerts.where((a) => a.status != AlertStatus.resolved && !a.blocked).length;

  /// Deletes this account and everything server-side tied to it, wipes what
  /// this phone keeps (parking, fuel log, documents, settings), then starts
  /// fresh as a new anonymous user.
  Future<void> deleteAccount() async {
    await _db.rpc('delete_my_account');
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    // The server no longer knows this user, so its logout call is refused
    // (403); the local session still has to go.
    try {
      await _db.auth.signOut(scope: SignOutScope.local);
    } catch (e) {
      debugPrint('sign-out after deletion: $e');
    }
    _unsubscribeAll();
    vehicle = null;
    vehicles = [];
    tag = null;
    alerts = [];
    family = [];
    contacts = [];
    await bootstrap();
  }

  Future<void> bootstrap() async {
    loading = true;
    loadError = null;
    notifyListeners();
    // A phone that has loaded its car before opens on the copy it kept, at
    // once: the tag, the garage and every on-device tool need no server, and
    // starting must not wait on the network. The server's answer replaces
    // the copy when it comes.
    final fromCopy = vehicle == null && _db.auth.currentSession != null && await _restoreCache();
    if (fromCopy) {
      loading = false;
      notifyListeners();
    }
    try {
      // Without a limit, a connection that accepts and then stalls (a captive
      // portal, a dead tunnel) leaves the loading screen up for a minute.
      await _signInAndLoad().timeout(_patience);
    } catch (e) {
      debugPrint('bootstrap failed: $e');
      if (fromCopy || await _restoreCache()) {
        _wentOffline();
      } else {
        loadErrorIsNetwork = isNetworkError(e);
        loadError = loadErrorIsNetwork
            ? tr('Couldn\'t reach Connect. Check your internet and try again.')
            : tr('Connect couldn\'t sign you in right now. We\'re on it — please try again in a few minutes. ({code})', {'code': errorCode(e)});
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  static const _patience = Duration(seconds: 15);

  Future<void> _signInAndLoad() async {
    if (_db.auth.currentSession == null) {
      await _db.auth.signInAnonymously();
    }
    try {
      await refresh();
    } on PostgrestException catch (e) {
      // A stored session that can no longer be refreshed leaves the client
      // on the bare anon key, which has no table access. Start a fresh one.
      if (e.code != '42501' && e.code != 'PGRST301') rethrow;
      debugPrint('session unusable (${e.code}); signing in again');
      await _db.auth.signOut(scope: SignOutScope.local);
      await _db.auth.signInAnonymously();
      await refresh();
    }
  }

  // Connection failures surface as different types depending on which client
  // failed (auth vs. REST) and the platform (dart:io vs. web), and those types
  // aren't all exported, so match on the runtime type name as a fallback.
  static bool isNetworkError(Object e) {
    if (e is AuthRetryableFetchException || e is TimeoutException) return true;
    // A proxy answering in the server's place (a tunnel that is down, a
    // gateway timeout) is the server being out of reach, not it refusing us.
    if (e is PostgrestException && _gateway.contains(e.code)) return true;
    if (e is AuthException && _gateway.contains(e.statusCode)) return true;
    final t = '${e.runtimeType} $e';
    return t.contains('SocketException') || t.contains('ClientException') ||
        t.contains('Failed host lookup') || t.contains('Connection refused');
  }

  static const _gateway = {'502', '503', '504', '520', '521', '522', '523', '524', '530'};

  /// A short code people can screenshot; the full error goes to the log.
  @visibleForTesting
  static String errorCode(Object e) => switch (e) {
        AuthApiException(:final code, :final statusCode) => 'auth ${code ?? statusCode}',
        AuthException(:final statusCode) => 'auth $statusCode',
        PostgrestException(:final code) => 'db $code',
        _ => e.runtimeType.toString(),
      };

  Future<void> refresh() async {
    // RLS returns cars the user owns and cars shared with them; show their own first.
    final rows = await _db.from('vehicles').select().order('created_at', ascending: true);
    _rows['vehicles'] = rows;
    vehicles = rows.map(Vehicle.fromJson).toList();
    final prefs = await SharedPreferences.getInstance();
    vehicle = _activeAmong(vehicles, prefs);
    if (vehicle != null) {
      final tags = await _db.from('tags').select().eq('vehicle_id', vehicle!.id).order('created_at', ascending: false).limit(1);
      _rows['tag'] = tags.firstOrNull;
      tag = tags.isEmpty ? null : Tag.fromJson(tags.first);
    } else {
      _rows['tag'] = null;
      tag = null;
    }
    await Future.wait([_loadAlerts(), _loadContacts(), _loadFamily(), _loadSocieties()]);
    await Notifications.scheduleExpiryReminders(vehicle);
    if (_foreground || !pushActive) _subscribe();
    offline = false;
    _retries = 0;
    _retry?.cancel();
    _saveSoon();
    notifyListeners();
    // The server answered, so anything this phone is carrying can go now.
    unawaited(WhisperStore.flush(deliverWhisper));
  }

  Vehicle? _activeAmong(List<Vehicle> all, SharedPreferences prefs) =>
      all.where((v) => v.id == prefs.getString(_activeKey)).firstOrNull ??
      all.where((v) => v.owner == userId).firstOrNull ??
      all.firstOrNull;

  // ---------------------------------------------------------------- offline copy

  /// The server rows behind what is on screen, saved so the app can open with
  /// no connection: showing your own tag must not need the internet.
  final Map<String, dynamic> _rows = {};
  static const _cacheKey = 'state_cache_v1';
  Timer? _save;
  Timer? _retry;
  int _retries = 0;

  void _saveSoon() => _save ??= Timer(const Duration(seconds: 1), () {
        _save = null;
        _saveCache();
      });

  Future<void> _saveCache() async {
    final id = userId;
    if (id == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode({'user': id, ..._rows}));
    } catch (e) {
      debugPrint('saving the offline copy failed: $e');
    }
  }

  /// Fills the state from the saved copy. False when there is none for this
  /// user, or it holds no car: without one there is nothing to show.
  Future<bool> _restoreCache() async {
    try {
      final id = userId;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (id == null || raw == null) return false;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['user'] != id) return false;
      final restored = restoreRows(j, id, prefs.getString(_activeKey));
      if (restored.vehicle == null) return false;
      vehicles = restored.vehicles;
      vehicle = restored.vehicle;
      tag = restored.tag;
      alerts = restored.alerts;
      contacts = restored.contacts;
      family = restored.family;
      societies = restored.societies;
      notices = restored.notices;
      _rows
        ..clear()
        ..addAll(j..remove('user'));
      return true;
    } catch (e) {
      debugPrint('offline copy unreadable: $e');
      return false;
    }
  }

  /// The saved rows as models. Pure, so the shape of the copy is tested
  /// without a phone or a server.
  @visibleForTesting
  static ({
    List<Vehicle> vehicles,
    Vehicle? vehicle,
    Tag? tag,
    List<CarAlert> alerts,
    List<EmergencyContact> contacts,
    List<FamilyMember> family,
    List<Society> societies,
    List<SocietyNotice> notices,
  }) restoreRows(Map<String, dynamic> j, String userId, String? activeId) {
    List<Map<String, dynamic>> rows(String k) => ((j[k] as List?) ?? const []).cast<Map<String, dynamic>>();
    final vehicles = rows('vehicles').map(Vehicle.fromJson).toList();
    final vehicle = vehicles.where((v) => v.id == activeId).firstOrNull ??
        vehicles.where((v) => v.owner == userId).firstOrNull ??
        vehicles.firstOrNull;
    final t = j['tag'] as Map<String, dynamic>?;
    return (
      vehicles: vehicles,
      vehicle: vehicle,
      // The copy holds the tag of the car that was on screen when it was saved.
      tag: t == null || t['vehicle_id'] != vehicle?.id ? null : Tag.fromJson(t),
      alerts: rows('alerts').map(CarAlert.fromJson).toList(),
      contacts: rows('contacts').map(EmergencyContact.fromJson).toList(),
      family: rows('family').map(FamilyMember.fromJson).toList(),
      societies: rows('societies').map((r) => Society.fromJson(r, userId)).toList(),
      notices: rows('notices').map(SocietyNotice.fromJson).toList(),
    );
  }

  /// Marks the app offline and tries the server again by itself, backing off
  /// from 5 s to 30 s. The banner's button retries at once.
  void _wentOffline() {
    offline = true;
    _retry?.cancel();
    final wait = Duration(seconds: const [5, 10, 20, 30][_retries.clamp(0, 3)]);
    _retries++;
    _retry = Timer(wait, () {
      if (_foreground) reload();
    });
  }

  /// Loads from the server again. When it can't be reached this keeps what is
  /// on screen and says so, instead of throwing. True when the load worked.
  Future<bool> reload() async {
    try {
      await refresh().timeout(_patience);
      return true;
    } catch (e) {
      debugPrint('reload failed: $e');
      if (isNetworkError(e)) {
        _wentOffline();
        notifyListeners();
      }
      return false;
    }
  }

  // ---------------------------------------------------------------- lifecycle + push

  /// True once this device has an FCM token registered. Alerts then reach a
  /// closed app by push, so the realtime socket is only held while the app is
  /// on screen: Supabase's free plan allows 200 concurrent connections.
  bool pushActive = false;
  bool _foreground = true;

  Future<void> registerPushToken(String token) async {
    await _db.rpc('register_push_token', params: {'p_token': token, 'p_platform': kIsWeb ? 'web' : 'android'});
    pushActive = true;
  }

  void onForeground() {
    _foreground = true;
    if (userId == null || vehicle == null) return;
    reload();
  }

  void onBackground() {
    _foreground = false;
    if (!pushActive) return;
    _unsubscribeAll();
  }

  void _unsubscribeAll() {
    for (final c in _channels.values) {
      _db.removeChannel(c);
    }
    _channels.clear();
  }

  Future<void> _loadFamily() async {
    if (vehicle == null) {
      _rows['family'] = const [];
      family = [];
      return;
    }
    final rows = await _db.from('vehicle_members').select().eq('vehicle_id', vehicle!.id).order('created_at', ascending: true);
    _rows['family'] = rows;
    family = rows.map(FamilyMember.fromJson).toList();
  }

  Future<void> _loadAlerts() async {
    final rows = await _db.from('alerts').select().order('updated_at', ascending: false).limit(100);
    _rows['alerts'] = rows;
    alerts = rows.map(CarAlert.fromJson).toList();
    _saveSoon();
  }

  Future<void> _loadContacts() async {
    final rows = await _db.from('emergency_contacts').select().order('created_at', ascending: true);
    _rows['contacts'] = rows;
    contacts = rows.map(EmergencyContact.fromJson).toList();
  }

  Future<void> _loadSocieties() async {
    try {
      await _fetchSocieties();
    } catch (e) {
      // Societies are optional; a backend without them (not yet migrated, or
      // briefly failing) mustn't keep the car and its alerts from loading.
      debugPrint('societies unavailable: $e');
      _rows['societies'] = const [];
      _rows['notices'] = const [];
      societies = [];
      notices = [];
    }
  }

  Future<void> _fetchSocieties() async {
    final rows = await _db.from('societies').select(Society.columns).order('created_at', ascending: true);
    _rows['societies'] = rows;
    societies = rows.map((r) => Society.fromJson(r, userId)).toList();
    if (societies.isEmpty) {
      _rows['notices'] = const [];
      notices = [];
      return;
    }
    final n = await _db
        .from('society_notices')
        .select('id, society_id, body, created_at')
        .inFilter('society_id', societies.map((x) => x.id).toList())
        .order('created_at', ascending: false)
        .limit(50);
    _rows['notices'] = n;
    notices = n.map(SocietyNotice.fromJson).toList();
  }

  /// Listens by vehicle rather than owner so family members get alerts too,
  /// and on every car in the account, not just the one on screen. Channels
  /// share one socket, so this does not add connections against the free
  /// plan's 200-connection limit.
  void _subscribe() {
    final ids = vehicles.map((v) => v.id).toSet();
    for (final gone in _channels.keys.where((k) => !ids.contains(k)).toList()) {
      _db.removeChannel(_channels.remove(gone)!);
    }
    for (final id in ids.where((id) => !_channels.containsKey(id))) {
      _channels[id] = _db
          .channel('vehicle-$id')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'alerts',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'vehicle_id', value: id),
            callback: (payload) async {
              final isNew = payload.eventType == PostgresChangeEvent.insert;
              await _loadAlerts();
              notifyListeners();
              if (isNew) {
                final a = CarAlert.fromJson(payload.newRecord);
                Notifications.showAlert(a, vehicles.where((v) => v.id == id).firstOrNull ?? vehicle);
              }
            },
          )
          .subscribe();
    }
  }

  // ---------------------------------------------------------------- vehicle + tag

  static const _activeKey = 'active_vehicle';

  /// Switches the car on screen. Alerts stay account-wide; the tag, "back by"
  /// status and renewals follow the selected car.
  Future<void> selectVehicle(String id) async {
    if (vehicle?.id == id) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, id);
    await refresh();
  }

  /// Adds another car (and its tag) and makes it the active one.
  Future<void> addVehicle(Map<String, dynamic> fields) async {
    final row = await _db.from('vehicles').insert(fields).select().single();
    final v = Vehicle.fromJson(row);
    await _db.from('tags').insert({'vehicle_id': v.id});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, v.id);
    await refresh();
  }

  Future<void> saveVehicle(Map<String, dynamic> fields) async {
    if (vehicle == null) {
      final row = await _db.from('vehicles').insert(fields).select().single();
      vehicle = Vehicle.fromJson(row);
      vehicles = [...vehicles, vehicle!];
      final t = await _db.from('tags').insert({'vehicle_id': vehicle!.id}).select().single();
      tag = Tag.fromJson(t);
      // The first car has to start listening for alerts straight away, not
      // only after the next refresh.
      _subscribe();
    } else {
      final row = await _db.from('vehicles').update(fields).eq('id', vehicle!.id).select().single();
      vehicle = Vehicle.fromJson(row);
      vehicles = [for (final v in vehicles) v.id == vehicle!.id ? vehicle! : v];
    }
    await Notifications.scheduleExpiryReminders(vehicle);
    notifyListeners();
  }

  // ---------------------------------------------------------------- "back by" status

  Future<void> setAway(DateTime backAt, String? note) async {
    if (vehicle == null) return;
    final row = await _db
        .from('vehicles')
        .update({'back_at': backAt.toUtc().toIso8601String(), 'away_note': note?.trim().isEmpty == true ? null : note?.trim()})
        .eq('id', vehicle!.id)
        .select()
        .single();
    vehicle = Vehicle.fromJson(row);
    notifyListeners();
  }

  Future<void> clearAway() async {
    if (vehicle == null) return;
    final row = await _db.from('vehicles').update({'back_at': null, 'away_note': null}).eq('id', vehicle!.id).select().single();
    vehicle = Vehicle.fromJson(row);
    notifyListeners();
  }

  // ---------------------------------------------------------------- medical info

  Future<void> saveMedical({String? bloodGroup, String? note, required bool share}) => saveVehicle({
        'blood_group': bloodGroup,
        'medical_note': note?.trim().isEmpty == true ? null : note?.trim(),
        'medical_share': share,
      });

  // ---------------------------------------------------------------- alert photos

  final _photoUrls = <String, (String, DateTime)>{};

  /// A short-lived link to an alert's photo, reused until it nears expiry.
  Future<String> alertPhotoUrl(String path) async {
    final hit = _photoUrls[path];
    if (hit != null && hit.$2.isAfter(DateTime.now())) return hit.$1;
    final url = await _db.storage.from('alert-photos').createSignedUrl(path, 3600);
    _photoUrls[path] = (url, DateTime.now().add(const Duration(minutes: 50)));
    return url;
  }

  // ---------------------------------------------------------------- societies

  Future<void> createSociety(String name, String? flat) async {
    await _db.rpc('create_society', params: {'p_name': name.trim(), 'p_flat': flat, 'p_vehicle': vehicle?.id});
    await _loadSocieties();
    notifyListeners();
  }

  /// Returns false for a wrong code.
  Future<bool> joinSociety(String code, String? flat) async {
    final id = await _db.rpc('join_society', params: {'p_code': code, 'p_flat': flat, 'p_vehicle': vehicle?.id});
    if (id == null) return false;
    await _loadSocieties();
    notifyListeners();
    return true;
  }

  Future<void> leaveSociety(String societyId) async {
    await _db.from('society_members').delete().eq('society_id', societyId).eq('member', userId!);
    await _loadSocieties();
    notifyListeners();
  }

  Future<void> deleteSociety(String societyId) async {
    await _db.from('societies').delete().eq('id', societyId);
    await _loadSocieties();
    notifyListeners();
  }

  Future<String?> societyJoinCode(String societyId) async =>
      await _db.rpc('society_join_code', params: {'p_society': societyId}) as String?;

  Future<SocietyStats> societyStats(String societyId) async {
    final j = await _db.rpc('society_stats', params: {'p_society': societyId}) as Map<String, dynamic>;
    return SocietyStats(members: j['members'] as int, tagged: j['tagged'] as int);
  }

  Future<List<RosterEntry>> societyRoster(String societyId) async {
    final rows = await _db.rpc('society_roster', params: {'p_society': societyId}) as List<dynamic>;
    return rows.cast<Map<String, dynamic>>().map(RosterEntry.fromJson).toList();
  }

  Future<void> removeResident(String societyId, String member) async {
    await _db.from('society_members').delete().eq('society_id', societyId).eq('member', member);
  }

  /// Plate-as-QR: the tag code of the Connect car with this plate, or null.
  /// The server only ever answers "a Connect car exists", never who owns it.
  Future<String?> findTagByPlate(String plate) async {
    try {
      final res = await _db.functions.invoke('scan', body: {'action': 'plate', 'plate': plate});
      final data = res.data;
      return data is Map ? data['code'] as String? : null;
    } on FunctionException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// RC details for a plate from the server's licensed provider. Without a
  /// provider token, or with no signal, falls back to demo data so the flow
  /// still runs. Never includes the owner's name from the server.
  /// Has the local vision model (on the laptop, through the `vehicle-vision`
  /// function) read a car or RC photo. Null when it can't be reached or
  /// answers nothing usable; callers fall back to on-device reading.
  Future<Map<String, String?>?> visionRead(String kind, List<int> jpeg) async {
    try {
      final res = await _db.functions
          .invoke('vehicle-vision', body: {'kind': kind, 'image': base64Encode(jpeg)})
          .timeout(const Duration(seconds: 100));
      final d = res.data;
      if (d is Map && d['fields'] is Map) {
        return {for (final e in (d['fields'] as Map).entries) '${e.key}': e.value as String?};
      }
    } catch (e) {
      debugPrint('vision read failed: $e');
    }
    return null;
  }

  Future<RcRecord> lookupRc(String plate) async {
    try {
      final res = await _db.functions.invoke('rc-lookup', body: {'plate': plate});
      final data = res.data;
      if (data is Map && data['vehicle'] is Map) {
        return RcRecord.fromServer(plate, {...Map<String, dynamic>.from(data['vehicle'] as Map), 'mock': data['mock']});
      }
    } on FunctionException catch (e) {
      if (e.status == 429) rethrow;
    } catch (_) {}
    return RcRecord.demo(plate);
  }

  /// Hands a message that reached this phone by sound to the server, as any
  /// phone standing at the car could: the plate it carries is the proof of
  /// presence, and its reference makes sure the owner gets it once however
  /// many phones heard it.
  Future<Delivery> deliverWhisper(HeardWhisper h) async {
    final w = h.whisper;
    try {
      final code = await findTagByPlate(w.plate);
      if (code == null) return Delivery.unknownCar;
      await _db.functions.invoke('scan', body: {
        'action': 'alert',
        'code': code,
        'plate_last4': w.plate.substring(w.plate.length - 4),
        'kind': w.kindWire,
        'lang': w.lang.code,
        'ref': w.ref(h.at),
        'via': 'sound',
      });
      return Delivery.delivered;
    } on FunctionException catch (e) {
      debugPrint('whisper delivery refused: ${e.status} ${e.details}');
      // Not on Connect, or no longer the car we thought: nothing more to do.
      // Anything else (a rate limit, a server fault) is worth another try.
      return e.status == 404 || e.status == 403 ? Delivery.unknownCar : Delivery.later;
    } catch (e) {
      debugPrint('whisper delivery waits: $e');
      return Delivery.later;
    }
  }

  /// Posts to everyone in the society, then asks the server to push it.
  Future<void> postNotice(String societyId, String body) async {
    final row = await _db.from('society_notices').insert({'society_id': societyId, 'body': body.trim()}).select('id').single();
    try {
      await _db.functions.invoke('notify', body: {'notice_id': row['id']});
    } catch (e) {
      // The notice is posted either way; members see it next time they open the app.
      debugPrint('notice push failed: $e');
    }
    await _loadSocieties();
    notifyListeners();
  }

  Future<void> deleteNotice(int id) async {
    await _db.from('society_notices').delete().eq('id', id);
    await _loadSocieties();
    notifyListeners();
  }

  // ---------------------------------------------------------------- live trips

  /// Returns the new trip's id and the secret for its share link.
  Future<({String id, String token})> startTrip(int hours) async {
    final j = await _db.rpc('start_trip', params: {'p_vehicle': vehicle?.id, 'p_hours': hours}) as Map<String, dynamic>;
    return (id: j['id'] as String, token: j['token'] as String);
  }

  Future<void> updateTrip(String id, Map<String, dynamic> fields) =>
      _db.from('trips').update(fields).eq('id', id).select('id');

  Future<bool> tripActive(String id) async {
    final row = await _db.from('trips').select('stopped, ends_at').eq('id', id).maybeSingle();
    return row != null && row['stopped'] != true && DateTime.parse(row['ends_at'] as String).isAfter(DateTime.now());
  }

  // ---------------------------------------------------------------- family

  /// A one-time code, valid 24 hours. Creating a new one cancels the old one.
  Future<String> createInvite() async {
    return await _db.rpc('create_vehicle_invite', params: {'p_vehicle': vehicle!.id}) as String;
  }

  /// Returns false for a wrong, used or expired code.
  Future<bool> joinFamily(String code, String name) async {
    final id = await _db.rpc('accept_vehicle_invite', params: {'p_code': code, 'p_name': name});
    if (id == null) return false;
    await refresh();
    return true;
  }

  Future<void> removeMember(String userId) async {
    await _db.from('vehicle_members').delete().eq('vehicle_id', vehicle!.id).eq('member', userId);
    await _loadFamily();
    notifyListeners();
  }

  Future<void> leaveFamily() async {
    await _db.from('vehicle_members').delete().eq('vehicle_id', vehicle!.id).eq('member', userId!);
    alerts = [];
    await refresh();
  }

  Future<void> setTagActive(bool active) async {
    if (tag == null) return;
    final row = await _db.from('tags').update({'active': active}).eq('code', tag!.code).select().single();
    tag = Tag.fromJson(row);
    notifyListeners();
  }

  /// Retires the current code (e.g. the sticker was photographed and shared)
  /// and issues a fresh one.
  Future<void> replaceTag() async {
    if (vehicle == null) return;
    if (tag != null) await _db.from('tags').update({'active': false}).eq('code', tag!.code);
    final t = await _db.from('tags').insert({'vehicle_id': vehicle!.id}).select().single();
    tag = Tag.fromJson(t);
    notifyListeners();
  }

  // ---------------------------------------------------------------- alerts

  Future<List<AlertMessage>> messages(String alertId) async {
    final rows = await _db.from('alert_messages').select().eq('alert_id', alertId).order('id', ascending: true);
    return rows.map(AlertMessage.fromJson).toList();
  }

  RealtimeChannel watchMessages(String alertId, void Function() onChange) {
    return _db
        .channel('alert-$alertId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'alert_messages',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'alert_id', value: alertId),
          callback: (_) => onChange(),
        )
        .subscribe();
  }

  Future<void> unwatch(RealtimeChannel c) => _db.removeChannel(c);

  Future<void> sendMessage(String alertId, String body) async {
    await _db.from('alert_messages').insert({'alert_id': alertId, 'sender': 'owner', 'body': body});
  }

  /// Opening an alert tells the person at the car that someone has seen it.
  /// Only the first open counts; failures are ignored (it is a courtesy).
  Future<void> markSeen(String alertId) async {
    final a = alerts.where((x) => x.id == alertId).firstOrNull;
    if (a == null || a.seenAt != null) return;
    try {
      await _db.from('alerts').update({'seen_at': DateTime.now().toUtc().toIso8601String()}).eq('id', alertId).filter('seen_at', 'is', null);
      await _loadAlerts();
      notifyListeners();
    } catch (e) {
      debugPrint('markSeen failed: $e');
    }
  }

  /// Who took [a], from this phone's point of view; null when nobody did or it
  /// was me.
  String? handlerName(CarAlert a) {
    final id = a.handledBy;
    if (id == null || id == userId) return null;
    final m = family.where((f) => f.userId == id).firstOrNull;
    return m?.name ?? tr('The owner');
  }

  Future<void> setStatus(String alertId, AlertStatus status) async {
    // Record who took it, so the rest of the family can see.
    await _db.from('alerts').update({'status': status.wire, 'handled_by': status == AlertStatus.open ? null : userId}).eq('id', alertId);
    await _loadAlerts();
    notifyListeners();
  }

  Future<void> blockSender(String alertId) async {
    await _db.rpc('block_alert_sender', params: {'p_alert': alertId});
    await _loadAlerts();
    notifyListeners();
  }

  // ---------------------------------------------------------------- contacts

  Future<void> addContact(String name, String phone) async {
    await _db.from('emergency_contacts').insert({'name': name, 'phone': phone});
    await _loadContacts();
    notifyListeners();
  }

  Future<void> removeContact(String id) async {
    await _db.from('emergency_contacts').delete().eq('id', id);
    await _loadContacts();
    notifyListeners();
  }

  @override
  void dispose() {
    _unsubscribeAll();
    _retry?.cancel();
    _save?.cancel();
    super.dispose();
  }
}
