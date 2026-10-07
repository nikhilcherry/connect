import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n.dart';
import '../services/notifications.dart';
import 'models.dart';

/// Single source of truth for the signed-in owner. v1 supports one vehicle
/// per account in the UI, though the schema allows several.
class AppState extends ChangeNotifier {
  AppState(this._db);

  final SupabaseClient _db;
  RealtimeChannel? _channel;

  bool loading = true;
  String? loadError;

  /// True when [loadError] is a connectivity problem rather than the server
  /// refusing us. The two need different screens: "Offline" for a server-side
  /// fault sends people checking their Wi-Fi for nothing.
  bool loadErrorIsNetwork = false;
  Vehicle? vehicle;
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
    await _db.auth.signOut(scope: SignOutScope.local);
    vehicle = null;
    alerts = [];
    await bootstrap();
  }

  Future<void> bootstrap() async {
    loading = true;
    loadError = null;
    notifyListeners();
    try {
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
    } catch (e) {
      loadErrorIsNetwork = isNetworkError(e);
      loadError = loadErrorIsNetwork
          ? tr('Couldn\'t reach Connect. Check your internet and try again.')
          : tr('Connect couldn\'t sign you in right now. We\'re on it — please try again in a few minutes. ({code})', {'code': errorCode(e)});
      debugPrint('bootstrap failed: $e');
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  // Connection failures surface as different types depending on which client
  // failed (auth vs. REST) and the platform (dart:io vs. web), and those types
  // aren't all exported, so match on the runtime type name as a fallback.
  @visibleForTesting
  static bool isNetworkError(Object e) {
    if (e is AuthRetryableFetchException || e is TimeoutException) return true;
    final t = '${e.runtimeType} $e';
    return t.contains('SocketException') || t.contains('ClientException') ||
        t.contains('Failed host lookup') || t.contains('Connection refused');
  }

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
    final vehicles = (await _db.from('vehicles').select().order('created_at', ascending: true)).map(Vehicle.fromJson).toList();
    vehicle = vehicles.where((v) => v.owner == userId).firstOrNull ?? vehicles.firstOrNull;
    if (vehicle != null) {
      final tags = await _db.from('tags').select().eq('vehicle_id', vehicle!.id).order('created_at', ascending: false).limit(1);
      tag = tags.isEmpty ? null : Tag.fromJson(tags.first);
    } else {
      tag = null;
    }
    await Future.wait([_loadAlerts(), _loadContacts(), _loadFamily(), _loadSocieties()]);
    await Notifications.scheduleExpiryReminders(vehicle);
    if (_foreground || !pushActive) _subscribe();
    notifyListeners();
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
    refresh().catchError((Object e) => debugPrint('resume refresh failed: $e'));
  }

  void onBackground() {
    _foreground = false;
    if (!pushActive || _channel == null) return;
    _db.removeChannel(_channel!);
    _channel = null;
    _channelVehicle = null;
  }

  Future<void> _loadFamily() async {
    if (vehicle == null) {
      family = [];
      return;
    }
    final rows = await _db.from('vehicle_members').select().eq('vehicle_id', vehicle!.id).order('created_at', ascending: true);
    family = rows.map(FamilyMember.fromJson).toList();
  }

  Future<void> _loadAlerts() async {
    final rows = await _db.from('alerts').select().order('updated_at', ascending: false).limit(100);
    alerts = rows.map(CarAlert.fromJson).toList();
  }

  Future<void> _loadContacts() async {
    final rows = await _db.from('emergency_contacts').select().order('created_at', ascending: true);
    contacts = rows.map(EmergencyContact.fromJson).toList();
  }

  String? _channelVehicle;

  Future<void> _loadSocieties() async {
    try {
      await _fetchSocieties();
    } catch (e) {
      // Societies are optional; a backend without them (not yet migrated, or
      // briefly failing) mustn't keep the car and its alerts from loading.
      debugPrint('societies unavailable: $e');
      societies = [];
      notices = [];
    }
  }

  Future<void> _fetchSocieties() async {
    final rows = await _db.from('societies').select(Society.columns).order('created_at', ascending: true);
    societies = rows.map((r) => Society.fromJson(r, userId)).toList();
    if (societies.isEmpty) {
      notices = [];
      return;
    }
    final n = await _db
        .from('society_notices')
        .select('id, society_id, body, created_at')
        .inFilter('society_id', societies.map((x) => x.id).toList())
        .order('created_at', ascending: false)
        .limit(50);
    notices = n.map(SocietyNotice.fromJson).toList();
  }

  /// Listens by vehicle rather than owner so family members get alerts too.
  void _subscribe() {
    final vid = vehicle?.id;
    if (vid == _channelVehicle) return;
    if (_channel != null) _db.removeChannel(_channel!);
    _channel = null;
    _channelVehicle = vid;
    if (vid == null) return;
    _channel = _db
        .channel('vehicle-$vid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'alerts',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'vehicle_id', value: vid),
          callback: (payload) async {
            final isNew = payload.eventType == PostgresChangeEvent.insert;
            await _loadAlerts();
            notifyListeners();
            if (isNew) {
              final a = CarAlert.fromJson(payload.newRecord);
              Notifications.showAlert(a, vehicle);
            }
          },
        )
        .subscribe();
  }

  // ---------------------------------------------------------------- vehicle + tag

  Future<void> saveVehicle(Map<String, dynamic> fields) async {
    if (vehicle == null) {
      final row = await _db.from('vehicles').insert(fields).select().single();
      vehicle = Vehicle.fromJson(row);
      final t = await _db.from('tags').insert({'vehicle_id': vehicle!.id}).select().single();
      tag = Tag.fromJson(t);
    } else {
      final row = await _db.from('vehicles').update(fields).eq('id', vehicle!.id).select().single();
      vehicle = Vehicle.fromJson(row);
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

  Future<void> setStatus(String alertId, AlertStatus status) async {
    await _db.from('alerts').update({'status': status.wire}).eq('id', alertId);
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
    if (_channel != null) _db.removeChannel(_channel!);
    super.dispose();
  }
}
