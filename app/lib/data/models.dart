import 'package:flutter/material.dart' show IconData, Icons;
import '../l10n.dart';

class Vehicle {
  Vehicle({
    required this.id,
    required this.owner,
    required this.regNumber,
    required this.make,
    required this.model,
    this.colour,
    this.nickname,
    this.lengthMm,
    this.widthMm,
    this.heightMm,
    this.pucExpiry,
    this.insuranceExpiry,
    this.serviceDue,
    this.backAt,
    this.awayNote,
    this.bloodGroup,
    this.medicalNote,
    this.medicalShare = false,
  });

  final String id;
  final String owner;
  final String regNumber;
  final String make;
  final String model;
  final String? colour;
  final String? nickname;
  final int? lengthMm;
  final int? widthMm;
  final int? heightMm;
  final DateTime? pucExpiry;
  final DateTime? insuranceExpiry;
  final DateTime? serviceDue;

  /// "Back by" time shown to people who message about the car.
  final DateTime? backAt;
  final String? awayNote;

  /// Emergency info for accident scans; see MedicalInfoScreen.
  final String? bloodGroup;
  final String? medicalNote;
  final bool medicalShare;

  bool get hasMedical => bloodGroup != null || (medicalNote?.isNotEmpty ?? false);

  bool get isAway => backAt != null && backAt!.isAfter(DateTime.now());

  String get title => nickname?.isNotEmpty == true ? nickname! : '$make $model';

  /// "KA01AB1234" -> "KA 01 AB 1234" for display.
  String get prettyReg {
    final m = RegExp(r'^([A-Z]{2})(\d{1,2})([A-Z]{0,3})(\d{1,4})$').firstMatch(regNumber);
    if (m == null) return regNumber;
    return [m[1], m[2], m[3], m[4]].where((s) => s != null && s.isNotEmpty).join(' ');
  }

  static DateTime? _date(dynamic v) => v == null ? null : DateTime.parse(v as String);

  factory Vehicle.fromJson(Map<String, dynamic> j) => Vehicle(
        id: j['id'] as String,
        owner: j['owner'] as String,
        regNumber: j['reg_number'] as String,
        make: j['make'] as String,
        model: j['model'] as String,
        colour: j['colour'] as String?,
        nickname: j['nickname'] as String?,
        lengthMm: j['length_mm'] as int?,
        widthMm: j['width_mm'] as int?,
        heightMm: j['height_mm'] as int?,
        pucExpiry: _date(j['puc_expiry']),
        insuranceExpiry: _date(j['insurance_expiry']),
        serviceDue: _date(j['service_due']),
        backAt: j['back_at'] == null ? null : DateTime.parse(j['back_at'] as String).toLocal(),
        awayNote: j['away_note'] as String?,
        bloodGroup: j['blood_group'] as String?,
        medicalNote: j['medical_note'] as String?,
        medicalShare: j['medical_share'] as bool? ?? false,
      );
}

class Tag {
  Tag({required this.code, required this.vehicleId, required this.active});
  final String code;
  final String vehicleId;
  final bool active;

  factory Tag.fromJson(Map<String, dynamic> j) =>
      Tag(code: j['code'] as String, vehicleId: j['vehicle_id'] as String, active: j['active'] as bool);
}

enum AlertKind {
  blocking(/*t*/'Blocking a car', Icons.no_crash_outlined),
  lightsOn(/*t*/'Lights are on', Icons.lightbulb_outline),
  towing(/*t*/'Being towed', Icons.car_crash_outlined),
  windowOpen(/*t*/'Window or door open', Icons.sensor_door_outlined),
  accident(/*t*/'Accident or damage', Icons.warning_amber_outlined),
  other(/*t*/'Message', Icons.chat_bubble_outline);

  const AlertKind(this.label, this.icon);
  final String label;
  final IconData icon;

  bool get urgent => this == towing || this == accident;

  static AlertKind parse(String s) => switch (s) {
        'blocking' => blocking,
        'lights_on' => lightsOn,
        'towing' => towing,
        'window_open' => windowOpen,
        'accident' => accident,
        _ => other,
      };
}

enum AlertStatus {
  open('open', /*t*/'New'),
  onMyWay('on_my_way', /*t*/'On my way'),
  resolved('resolved', /*t*/'Sorted');

  const AlertStatus(this.wire, this.label);
  final String wire;
  final String label;

  static AlertStatus parse(String s) => values.firstWhere((v) => v.wire == s, orElse: () => open);
}

class CarAlert {
  CarAlert({
    required this.id,
    required this.vehicleId,
    required this.kind,
    required this.status,
    required this.blocked,
    required this.createdAt,
    required this.updatedAt,
    this.note,
    this.photoPath,
    this.scannerLang = AppLang.en,
    this.seenAt,
  });

  final String id;
  final String vehicleId;
  final AlertKind kind;

  /// The language the person at the car chose on the scan page.
  final AppLang scannerLang;

  /// When the owner (or family) first opened this alert; the person at the car
  /// is told "the owner has seen your message".
  final DateTime? seenAt;
  final AlertStatus status;
  final bool blocked;
  final String? note;

  /// Object name in the private alert-photos bucket; gone after 7 days.
  final String? photoPath;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory CarAlert.fromJson(Map<String, dynamic> j) => CarAlert(
        id: j['id'] as String,
        vehicleId: j['vehicle_id'] as String,
        kind: AlertKind.parse(j['kind'] as String),
        status: AlertStatus.parse(j['status'] as String),
        blocked: j['blocked'] as bool? ?? false,
        note: j['note'] as String?,
        photoPath: j['photo_path'] as String?,
        scannerLang: AppLang.values.firstWhere((l) => l.code == j['scanner_lang'], orElse: () => AppLang.en),
        seenAt: j['seen_at'] == null ? null : DateTime.parse(j['seen_at'] as String).toLocal(),
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
        updatedAt: DateTime.parse(j['updated_at'] as String).toLocal(),
      );
}

class AlertMessage {
  AlertMessage({required this.id, required this.fromOwner, required this.body, required this.createdAt});
  final int id;
  final bool fromOwner;
  final String body;
  final DateTime createdAt;

  factory AlertMessage.fromJson(Map<String, dynamic> j) => AlertMessage(
        id: j['id'] as int,
        fromOwner: j['sender'] == 'owner',
        body: j['body'] as String,
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
      );
}

class EmergencyContact {
  EmergencyContact({required this.id, required this.name, required this.phone});
  final String id;
  final String name;
  final String phone;

  factory EmergencyContact.fromJson(Map<String, dynamic> j) =>
      EmergencyContact(id: j['id'] as String, name: j['name'] as String, phone: j['phone'] as String);
}

class FamilyMember {
  FamilyMember({required this.userId, required this.name, required this.joinedAt});
  final String userId;
  final String name;
  final DateTime joinedAt;

  factory FamilyMember.fromJson(Map<String, dynamic> j) => FamilyMember(
        userId: j['member'] as String,
        name: j['display_name'] as String,
        joinedAt: DateTime.parse(j['created_at'] as String).toLocal(),
      );
}

/// A housing society or office car park the user belongs to.
class Society {
  Society({required this.id, required this.name, required this.admin, required this.isAdmin});
  final String id;
  final String name;
  final String admin;
  final bool isAdmin;

  /// `societies` has column-level grants (the join code is private), so
  /// always select exactly these.
  static const columns = 'id, name, admin';

  factory Society.fromJson(Map<String, dynamic> j, String? me) =>
      Society(id: j['id'] as String, name: j['name'] as String, admin: j['admin'] as String, isAdmin: j['admin'] == me);
}

class SocietyNotice {
  SocietyNotice({required this.id, required this.societyId, required this.body, required this.createdAt});
  final int id;
  final String societyId;
  final String body;
  final DateTime createdAt;

  factory SocietyNotice.fromJson(Map<String, dynamic> j) => SocietyNotice(
        id: j['id'] as int,
        societyId: j['society_id'] as String,
        body: j['body'] as String,
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
      );
}

class SocietyStats {
  SocietyStats({required this.members, required this.tagged});
  final int members;
  final int tagged;
}

class RosterEntry {
  RosterEntry({required this.member, this.flat, this.car, required this.tagged});
  final String member;
  final String? flat;
  final String? car;
  final bool tagged;

  factory RosterEntry.fromJson(Map<String, dynamic> j) => RosterEntry(
        member: j['member'] as String,
        flat: j['flat'] as String?,
        car: j['car'] as String?,
        tagged: j['tagged'] as bool? ?? false,
      );
}
