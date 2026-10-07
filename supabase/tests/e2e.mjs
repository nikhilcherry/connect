// End-to-end check of the Connect backend against a running Supabase stack.
// The functions server must run with supabase/functions/.env.local (SCAN_IP_HOP=first)
// so each simulated sender IP counts as a different person.
//   node supabase/tests/e2e.mjs            (defaults to local `supabase start`)
//   SUPABASE_URL=... SUPABASE_ANON_KEY=... node supabase/tests/e2e.mjs
// Uses anonymous sign-ins, so it needs enable_anonymous_sign_ins = true.

const URL_ = process.env.SUPABASE_URL ?? "http://127.0.0.1:54321";
const ANON = process.env.SUPABASE_ANON_KEY ?? "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH";

let passed = 0;
function check(cond, name, detail) {
  if (!cond) {
    console.error(`FAIL  ${name}`, JSON.stringify(detail ?? ""));
    process.exit(1);
  }
  passed++;
  console.log(`ok    ${name}`);
}

async function signIn() {
  const r = await fetch(`${URL_}/auth/v1/signup`, {
    method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json" },
    body: "{}",
  });
  const j = await r.json();
  if (!j.access_token) throw new Error(`anonymous sign-in failed: ${JSON.stringify(j)}`);
  return j.access_token;
}

async function rest(token, method, path, body) {
  const r = await fetch(`${URL_}/rest/v1/${path}`, {
    method,
    headers: {
      apikey: ANON,
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  return { status: r.status, data: text ? JSON.parse(text) : null };
}

async function scan(payload, ip) {
  const r = await fetch(`${URL_}/functions/v1/scan`, {
    method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json", "x-forwarded-for": ip },
    body: JSON.stringify(payload),
  });
  return { status: r.status, data: await r.json() };
}

const rnd = () => Math.floor(Math.random() * 250);
const plate = `KA01AB${Math.floor(1000 + Math.random() * 9000)}`;
const last4 = plate.slice(-4);
const ip = `198.51.100.${rnd()}`;

const owner = await signIn();
const stranger = await signIn();

// --- owner setup
const v = await rest(owner, "POST", "vehicles", { reg_number: plate, make: "Maruti Suzuki", model: "Swift", colour: "Grey" });
check(v.status === 201, "owner creates vehicle", v);
const vehicleId = v.data[0].id;

const tag = await rest(owner, "POST", "tags", { vehicle_id: vehicleId });
check(tag.status === 201 && /^[A-Z2-9]{8}$/.test(tag.data[0].code), "owner creates tag with 8-char code", tag);
const code = tag.data[0].code;

// --- isolation
const peek = await rest(stranger, "GET", `vehicles?id=eq.${vehicleId}`);
check(peek.status === 200 && peek.data.length === 0, "another user cannot see the vehicle", peek);
const steal = await rest(stranger, "POST", "tags", { vehicle_id: vehicleId });
check(steal.status >= 400, "another user cannot tag someone else's vehicle", steal);
const anonRead = await fetch(`${URL_}/rest/v1/vehicles?select=reg_number`, { headers: { apikey: ANON } });
check(anonRead.status >= 400 || (await anonRead.json()).length === 0, "anon key cannot list vehicles", anonRead.status);

// --- scanner flow
const look = await scan({ action: "lookup", code }, ip);
check(look.status === 200 && look.data.model === "Swift" && !("reg_number" in look.data), "lookup shows car but not plate", look);

const byPlate = await scan({ action: "plate", plate: plate.toLowerCase().replace(/(.{4})/, "$1 ") }, "10.9.0.1");
check(byPlate.status === 200 && byPlate.data.code === code && Object.keys(byPlate.data).length === 1, "plate-as-QR returns only the tag code", byPlate);
const noPlate = await scan({ action: "plate", plate: "KA01ZZ9999" }, "10.9.0.2");
check(noPlate.status === 404 && noPlate.data.error === "tag_not_found", "unknown plate is 404", noPlate);
// A plate registered by two accounts is ambiguous: never route to either.
{
  const dup = await signIn();
  const dv = await rest(dup, "POST", "vehicles", { reg_number: plate, make: "Honda", model: "City" });
  await rest(dup, "POST", "tags", { vehicle_id: dv.data[0].id });
  const amb = await scan({ action: "plate", plate }, "10.9.0.4");
  check(amb.status === 404, "a plate claimed by two accounts is not resolved", amb);
  await rest(dup, "DELETE", `vehicles?id=eq.${dv.data[0].id}`);
}
let plateCapped = null;
for (let i = 0; i < 6; i++) plateCapped = await scan({ action: "plate", plate: `KA01ZZ99${10 + i}` }, "10.9.0.3");
check(plateCapped.status === 429, "plate guessing is rate-limited per sender", plateCapped);

const bad = await scan({ action: "lookup", code: "ZZZZZZZZ" }, ip);
check(bad.status === 404, "unknown tag is 404", bad);

const wrong = await scan({ action: "alert", code, kind: "blocking", plate_last4: "0000" }, ip);
check(wrong.status === 403 && wrong.data.error === "plate_mismatch", "wrong plate digits rejected", wrong);

const sent = await scan({ action: "alert", code, kind: "blocking", plate_last4: last4.toLowerCase(), note: "Blocking gate 2" }, ip);
check(sent.status === 200 && sent.data.alert_id && sent.data.token, "alert sent with correct plate", sent);
const { alert_id, token } = sent.data;

// --- owner side
const inbox = await rest(owner, "GET", `alerts?select=id,kind,note,status&id=eq.${alert_id}`);
check(inbox.data.length === 1 && inbox.data[0].note === "Blocking gate 2", "owner sees the alert", inbox);
const hashes = await rest(owner, "GET", "alert_scanners?select=*");
check(hashes.status >= 400, "owner cannot read scanner hashes", hashes);
const strangerInbox = await rest(stranger, "GET", `alerts?id=eq.${alert_id}`);
check(strangerInbox.data.length === 0, "another user cannot see the alert", strangerInbox);

const replyOwner = await rest(owner, "POST", "alert_messages", { alert_id, sender: "owner", body: "Coming in 2 minutes" });
check(replyOwner.status === 201, "owner replies", replyOwner);
const spoof = await rest(owner, "POST", "alert_messages", { alert_id, sender: "scanner", body: "fake" });
check(spoof.status >= 400, "owner cannot post as scanner", spoof);
const hijack = await rest(stranger, "POST", "alert_messages", { alert_id, sender: "owner", body: "hi" });
check(hijack.status >= 400, "another user cannot post into the alert", hijack);

const onWay = await rest(owner, "PATCH", `alerts?id=eq.${alert_id}`, { status: "on_my_way" });
check(onWay.status === 200 && onWay.data[0].status === "on_my_way", "owner marks on my way", onWay);
const reassign = await rest(owner, "PATCH", `alerts?id=eq.${alert_id}`, { note: "edited" });
check(reassign.status >= 400, "owner cannot edit other alert columns", reassign);

// --- scanner sees reply
const thread = await scan({ action: "thread", alert_id, token }, ip);
check(thread.data.status === "on_my_way" && thread.data.note === "Blocking gate 2" && thread.data.messages.map((m) => m.body).join("|") === "Coming in 2 minutes",
  "scanner sees status and owner reply", thread);
const forged = await scan({ action: "thread", alert_id, token: "nope" }, ip);
check(forged.data.messages.length === 0, "wrong token sees nothing", forged);

const scannerReply = await scan({ action: "reply", alert_id, token, body: "Thanks, waiting" }, ip);
check(scannerReply.status === 200, "scanner replies", scannerReply);
const ownerMsgs = await rest(owner, "GET", `alert_messages?alert_id=eq.${alert_id}&order=id`);
check(ownerMsgs.data.map((m) => m.sender).join(",") === "owner,scanner", "owner sees both messages in order", ownerMsgs);

// --- blocking
const block = await rest(owner, "POST", "rpc/block_alert_sender", { p_alert: alert_id });
check(block.status === 204 || block.status === 200, "owner blocks sender", block);
const afterBlock = await scan({ action: "alert", code, kind: "other", plate_last4: last4 }, ip);
check(afterBlock.status === 200, "blocked sender gets a normal-looking response", afterBlock);
const count = await rest(owner, "GET", `alerts?select=id&vehicle_id=eq.${vehicleId}`);
check(count.data.length === 1, "but no new alert reaches the owner", count);
const otherIp = await scan({ action: "alert", code, kind: "lights_on", plate_last4: last4 }, `192.0.2.${rnd()}`);
check(otherIp.status === 200, "a different sender still gets through", otherIp);
const count2 = await rest(owner, "GET", `alerts?select=id&vehicle_id=eq.${vehicleId}`);
check(count2.data.length === 2, "and their alert arrives", count2);

// --- "back by" status
const later = new Date(Date.now() + 45 * 60_000).toISOString();
const away = await rest(owner, "PATCH", `vehicles?id=eq.${vehicleId}`, { back_at: later, away_note: "In the pharmacy" });
check(away.status === 200 && away.data[0].away_note === "In the pharmacy", "owner sets 'back by' status", away);
const lookAway = await scan({ action: "lookup", code }, ip);
check(!("back_at" in lookAway.data) && !JSON.stringify(lookAway.data).includes("pharmacy"), "lookup never reveals when the car is unattended", lookAway);
const t2 = await scan({ action: "thread", ...otherIp.data }, `192.0.2.${rnd()}`);
check(t2.data.owner_status?.note === "In the pharmacy" && new Date(t2.data.owner_status.back_at).getTime() === new Date(later).getTime(),
  "sender who passed the plate check sees 'back by'", t2);
const tForged = await scan({ action: "thread", alert_id: otherIp.data.alert_id, token: "nope" }, ip);
check(!tForged.data.owner_status, "wrong token doesn't see 'back by'", tForged);
await rest(owner, "PATCH", `vehicles?id=eq.${vehicleId}`, { back_at: new Date(Date.now() - 60_000).toISOString() });
const t3 = await scan({ action: "thread", ...otherIp.data }, ip);
check(t3.data.owner_status === null, "past 'back by' time is not shown", t3);

// --- family sharing
const member = await signIn();
const third = await signIn();
const noCar = await rest(member, "GET", `vehicles?id=eq.${vehicleId}`);
check(noCar.data.length === 0, "before joining, a family member sees nothing", noCar);
const notOwnerInvite = await rest(member, "POST", "rpc/create_vehicle_invite", { p_vehicle: vehicleId });
check(notOwnerInvite.status >= 400, "only the owner can create an invite", notOwnerInvite);
const inv = await rest(owner, "POST", "rpc/create_vehicle_invite", { p_vehicle: vehicleId });
check(inv.status === 200 && /^[A-Z2-9]{6}$/.test(inv.data), "owner creates a 6-char invite code", inv);
const ownInvites = await rest(owner, "GET", "vehicle_invites");
check(ownInvites.status >= 400, "invite codes can't be listed through the API", ownInvites);
const badJoin = await rest(member, "POST", "rpc/accept_vehicle_invite", { p_code: "AAAAAA", p_name: "Amma" });
check(badJoin.status === 200 && badJoin.data === null, "wrong invite code joins nothing", badJoin);
const join = await rest(member, "POST", "rpc/accept_vehicle_invite", { p_code: inv.data.toLowerCase(), p_name: "Amma" });
check(join.data === vehicleId, "family member joins with the code", join);
const reuse = await rest(third, "POST", "rpc/accept_vehicle_invite", { p_code: inv.data, p_name: "X" });
check(reuse.data === null, "an invite code works only once", reuse);

const mCar = await rest(member, "GET", `vehicles?id=eq.${vehicleId}`);
check(mCar.data.length === 1 && mCar.data[0].reg_number === plate, "member sees the car", mCar);
const mTag = await rest(member, "GET", `tags?vehicle_id=eq.${vehicleId}`);
check(mTag.data.length === 1, "member sees the tag", mTag);
const mAlerts = await rest(member, "GET", `alerts?vehicle_id=eq.${vehicleId}`);
check(mAlerts.data.length === 2, "member sees the car's alerts", mAlerts);
const mReply = await rest(member, "POST", "alert_messages", { alert_id: otherIp.data.alert_id, sender: "owner", body: "Amma here, coming" });
check(mReply.status === 201, "member replies to a stranger", mReply);
const tMember = await scan({ action: "thread", ...otherIp.data }, ip);
check(tMember.data.messages.some((m) => m.body === "Amma here, coming"), "stranger sees the member's reply", tMember);
const mStatus = await rest(member, "PATCH", `alerts?id=eq.${otherIp.data.alert_id}`, { status: "on_my_way" });
check(mStatus.status === 200 && mStatus.data[0].status === "on_my_way", "member marks on my way", mStatus);
const mAway = await rest(member, "PATCH", `vehicles?id=eq.${vehicleId}`, { back_at: later });
check(mAway.status === 200 && mAway.data.length === 1, "member sets 'back by'", mAway);
const mPlate = await rest(member, "PATCH", `vehicles?id=eq.${vehicleId}`, { reg_number: "KA01ZZ0000" });
check(mPlate.status >= 400, "member cannot change the number plate", mPlate);
const oPlate = await rest(owner, "PATCH", `vehicles?id=eq.${vehicleId}`, { nickname: "Family car" });
check(oPlate.status === 200, "owner can still edit the car", oPlate);
const mTagOff = await rest(member, "PATCH", `tags?code=eq.${code}`, { active: false });
check(mTagOff.status === 200 && mTagOff.data.length === 0, "member cannot pause the tag", mTagOff);
const mDelete = await rest(member, "DELETE", `vehicles?id=eq.${vehicleId}`);
const stillThere = await rest(owner, "GET", `vehicles?id=eq.${vehicleId}`);
check(stillThere.data.length === 1, "member cannot delete the car", mDelete);
const mTakeover = await rest(member, "PATCH", `vehicles?id=eq.${vehicleId}`, { owner: "00000000-0000-0000-0000-000000000000" });
check(mTakeover.status >= 400, "nobody can move the car to another account", mTakeover);
const mInvite = await rest(member, "POST", "rpc/create_vehicle_invite", { p_vehicle: vehicleId });
check(mInvite.status >= 400, "member cannot invite others", mInvite);
const roster = await rest(owner, "GET", `vehicle_members?vehicle_id=eq.${vehicleId}`);
check(roster.data.length === 1 && roster.data[0].display_name === "Amma", "owner sees who's in the family", roster);
const thirdSees = await rest(third, "GET", `alerts?vehicle_id=eq.${vehicleId}`);
check(thirdSees.data.length === 0, "someone outside the family still sees nothing", thirdSees);
const leave = await rest(member, "DELETE", `vehicle_members?vehicle_id=eq.${vehicleId}&member=eq.${JSON.parse(atob(member.split(".")[1])).sub}`);
check(leave.status === 200 && leave.data.length === 1, "member leaves", leave);
const gone = await rest(member, "GET", `alerts?vehicle_id=eq.${vehicleId}`);
check(gone.data.length === 0, "after leaving, alerts disappear", gone);

const inv2 = await rest(owner, "POST", "rpc/create_vehicle_invite", { p_vehicle: vehicleId });
await rest(third, "POST", "rpc/accept_vehicle_invite", { p_code: inv2.data, p_name: "Driver" });
const kick = await rest(owner, "DELETE", `vehicle_members?vehicle_id=eq.${vehicleId}`);
check(kick.data.length === 1, "owner removes a member", kick);
for (let i = 0; i < 10; i++) await rest(member, "POST", "rpc/accept_vehicle_invite", { p_code: "BBBBBB", p_name: "x" });
const inv3 = await rest(owner, "POST", "rpc/create_vehicle_invite", { p_vehicle: vehicleId });
const lockedJoin = await rest(member, "POST", "rpc/accept_vehicle_invite", { p_code: inv3.data, p_name: "Amma" });
check(lockedJoin.status >= 400 && lockedJoin.data.message === "too_many_attempts", "10 wrong invite codes lock joining for an hour", lockedJoin);

// --- medical info on accident scans
const setMed = await rest(owner, "PATCH", `vehicles?id=eq.${vehicleId}`, { blood_group: "B+", medical_note: "Allergic to penicillin", medical_share: true });
check(setMed.status === 200 && setMed.data[0].blood_group === "B+", "owner saves medical info", setMed);
const badBlood = await rest(owner, "PATCH", `vehicles?id=eq.${vehicleId}`, { blood_group: "Z+" });
check(badBlood.status >= 400, "blood group must be a real one", badBlood);
const medIp = `198.18.0.${rnd()}`;
const lookMed = await scan({ action: "lookup", code }, medIp);
check(!JSON.stringify(lookMed.data).includes("penicillin") && !JSON.stringify(lookMed.data).includes("B+"), "lookup never shows medical info", lookMed);
const tBlocking = await scan({ action: "thread", ...otherIp.data }, medIp);
check(tBlocking.data.medical === null, "non-accident alerts don't get medical info", tBlocking);

// --- photos on alerts
const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(200, 7), Buffer.from([0xff, 0xd9])]).toString("base64");
const notJpeg = await scan({ action: "alert", code, kind: "accident", plate_last4: last4, photo: Buffer.from("hello world").toString("base64") }, medIp);
check(notJpeg.status === 400 && notJpeg.data.error === "bad_photo", "non-JPEG photo rejected", notJpeg);
const acc = await scan({ action: "alert", code, kind: "accident", plate_last4: last4, note: "Scraped at the gate", photo: `data:image/jpeg;base64,${jpeg}` }, medIp);
check(acc.status === 200, "accident alert with a photo is sent", acc);
const tAcc = await scan({ action: "thread", ...acc.data }, medIp);
check(tAcc.data.medical?.blood_group === "B+" && tAcc.data.medical?.note === "Allergic to penicillin", "accident sender sees shared medical info", tAcc);
const accRow = await rest(owner, "GET", `alerts?id=eq.${acc.data.alert_id}&select=photo_path`);
check(accRow.data[0]?.photo_path === `${acc.data.alert_id}.jpg`, "owner sees the alert's photo path", accRow);
const sign = (tok) => fetch(`${URL_}/storage/v1/object/sign/alert-photos/${acc.data.alert_id}.jpg`, {
  method: "POST",
  headers: { apikey: ANON, Authorization: `Bearer ${tok}`, "Content-Type": "application/json" },
  body: JSON.stringify({ expiresIn: 60 }),
});
const ownSign = await sign(owner);
check(ownSign.status === 200, "owner gets a signed URL for the photo", ownSign.status);
const img = await fetch(`${URL_}/storage/v1${(await ownSign.json()).signedURL}`);
check(img.status === 200 && (await img.arrayBuffer()).byteLength === 206, "the signed URL serves the photo", img.status);
const strangerSign = await sign(stranger);
check(strangerSign.status >= 400, "another user cannot open the photo", strangerSign.status);
await rest(owner, "PATCH", `vehicles?id=eq.${vehicleId}`, { medical_share: false });
const tAcc2 = await scan({ action: "thread", ...acc.data }, medIp);
check(tAcc2.data.medical === null, "medical info hidden once sharing is off", tAcc2);

// --- push tokens
const devToken = `fcm-test-token-${Math.random().toString(36).slice(2)}-abcdefghij`;
const reg = await rest(owner, "POST", "rpc/register_push_token", { p_token: devToken, p_platform: "android" });
check(reg.status === 204 || reg.status === 200, "owner registers a push token", reg);
const myTokens = await rest(owner, "GET", "push_tokens?select=token");
check(myTokens.data.some((t) => t.token === devToken), "owner sees their own token", myTokens);
const peekTokens = await rest(stranger, "GET", `push_tokens?token=eq.${devToken}`);
check(peekTokens.data.length === 0, "another user cannot see the token", peekTokens);
const rawInsert = await rest(stranger, "POST", "push_tokens", { token: `${devToken}-2`, user_id: JSON.parse(atob(owner.split(".")[1])).sub });
check(rawInsert.status >= 400, "tokens can't be inserted for someone else", rawInsert);
await rest(stranger, "POST", "rpc/register_push_token", { p_token: devToken });
const moved = await rest(owner, "GET", `push_tokens?token=eq.${devToken}`);
check(moved.data.length === 0, "re-registering on a new account takes the token over", moved);

// --- housing society
const soc = await rest(owner, "POST", "rpc/create_society", { p_name: "Prestige Lakeside", p_flat: "A-101", p_vehicle: vehicleId });
check(soc.status === 200 && typeof soc.data === "string", "owner creates a society", soc);
const socId = soc.data;
const joinCode = await rest(owner, "POST", "rpc/society_join_code", { p_society: socId });
check(/^[A-Z2-9]{6}$/.test(joinCode.data), "admin reads the join code", joinCode);
const codeCol = await rest(owner, "GET", `societies?id=eq.${socId}&select=join_code`);
check(codeCol.status >= 400, "join code can't be read through a select", codeCol);
const outsiderSoc = await rest(stranger, "GET", `societies?id=eq.${socId}&select=id,name`);
check(outsiderSoc.data.length === 0, "outsiders can't see the society", outsiderSoc);
const wrongSoc = await rest(third, "POST", "rpc/join_society", { p_code: "ZZZZZZ", p_flat: "B-2" });
check(wrongSoc.data === null, "wrong society code joins nothing", wrongSoc);
const stealCar = await rest(stranger, "POST", "rpc/join_society", { p_code: joinCode.data, p_flat: "B-204", p_vehicle: vehicleId });
check(stealCar.status >= 400, "can't join with someone else's car", stealCar);
const sJoin = await rest(stranger, "POST", "rpc/join_society", { p_code: joinCode.data.toLowerCase(), p_flat: "B-204" });
check(sJoin.data === socId, "resident joins with the code", sJoin);
const memberCode = await rest(stranger, "POST", "rpc/society_join_code", { p_society: socId });
check(memberCode.data === null, "members don't get the join code", memberCode);
const stats = await rest(stranger, "POST", "rpc/society_stats", { p_society: socId });
check(stats.data.members === 2 && stats.data.tagged === 1, "members see member and tagged-car counts", stats);
const rosterAdmin = await rest(owner, "POST", "rpc/society_roster", { p_society: socId });
check(rosterAdmin.data.length === 2 && rosterAdmin.data.some((r) => r.car?.includes("Swift") && r.tagged) &&
  !JSON.stringify(rosterAdmin.data).includes(plate), "admin sees the roster without plates", rosterAdmin);
const rosterMember = await rest(stranger, "POST", "rpc/society_roster", { p_society: socId });
check(rosterMember.status >= 400, "members can't see the roster", rosterMember);
const peers = await rest(stranger, "GET", `society_members?society_id=eq.${socId}`);
check(peers.data.length === 1, "members see only their own membership row", peers);
const notice = await rest(owner, "POST", "society_notices", { society_id: socId, body: "Move cars for cleaning, Sunday 8am" });
check(notice.status === 201, "admin posts a notice", notice);
const fakeNotice = await rest(stranger, "POST", "society_notices", { society_id: socId, body: "Free parking!" });
check(fakeNotice.status >= 400, "members can't post notices", fakeNotice);
const forgedPush = await rest(owner, "POST", "society_notices", { society_id: socId, body: "x", pushed_at: new Date().toISOString() });
check(forgedPush.status >= 400, "the app can't mark a notice as pushed", forgedPush);
const readNotices = await rest(stranger, "GET", `society_notices?society_id=eq.${socId}`);
check(readNotices.data.length === 1 && readNotices.data[0].body.includes("Sunday"), "members read notices", readNotices);
const outsiderNotices = await rest(third, "GET", `society_notices?society_id=eq.${socId}`);
check(outsiderNotices.data.length === 0, "outsiders can't read notices", outsiderNotices);
const notify = (tok, id) => fetch(`${URL_}/functions/v1/notify`, {
  method: "POST",
  headers: { apikey: ANON, Authorization: `Bearer ${tok}`, "Content-Type": "application/json" },
  body: JSON.stringify({ notice_id: id }),
}).then(async (r) => ({ status: r.status, data: await r.json() }));
const memberNotify = await notify(stranger, notice.data[0].id);
check(memberNotify.status === 404, "only the author can push a notice", memberNotify);
const push1 = await notify(owner, notice.data[0].id);
check(push1.status === 200 && push1.data.recipients === 1, "admin pushes the notice to members", push1);
const push2 = await notify(owner, notice.data[0].id);
check(push2.status === 404, "a notice is pushed only once", push2);
const anonNotify = await notify(ANON, notice.data[0].id);
check(anonNotify.status === 401, "notify needs a signed-in user", anonNotify);
const adminLeave = await rest(owner, "DELETE", `society_members?society_id=eq.${socId}&member=eq.${JSON.parse(atob(owner.split(".")[1])).sub}`);
check(adminLeave.data.length === 0, "the admin can't leave their own society", adminLeave);
const sLeave = await rest(stranger, "DELETE", `society_members?society_id=eq.${socId}&member=eq.${JSON.parse(atob(stranger.split(".")[1])).sub}`);
check(sLeave.data.length === 1, "a resident leaves", sLeave);
const afterLeave = await rest(stranger, "GET", `society_notices?society_id=eq.${socId}`);
check(afterLeave.data.length === 0, "after leaving, notices disappear", afterLeave);

// --- live trip sharing
const trip = await rest(owner, "POST", "rpc/start_trip", { p_vehicle: vehicleId, p_hours: 2 });
check(trip.status === 200 && /^[0-9a-f]{36}$/.test(trip.data.token), "owner starts a trip and gets a share token", trip);
const noHash = await rest(owner, "GET", `trips?id=eq.${trip.data.id}&select=token_hash`);
check(noHash.status >= 400, "the token hash can't be read back", noHash);
const beforeFix = await scan({ action: "trip", token: trip.data.token }, ip);
check(beforeFix.status === 200 && beforeFix.data.ended === false && beforeFix.data.lat === null, "viewer sees a trip waiting for its first fix", beforeFix);
const move = await rest(owner, "PATCH", `trips?id=eq.${trip.data.id}&select=id,lat`, {
  lat: 12.9716, lng: 77.5946, speed_mps: 11.5, accuracy_m: 8, trail: [[12.97, 77.59], [12.9716, 77.5946]], updated_at: new Date().toISOString(),
});
check(move.status === 200 && move.data.length === 1, "owner's phone updates the position", move);
const view = await scan({ action: "trip", token: trip.data.token }, ip);
check(view.data.lat === 12.9716 && view.data.car === "Grey Maruti Suzuki Swift" && view.data.trail.length === 2, "viewer sees the live position", view);
const hijackTrip = await rest(stranger, "PATCH", `trips?id=eq.${trip.data.id}&select=id,lat`, { lat: 0, lng: 0 });
check(hijackTrip.data.length === 0, "another user cannot move the trip", hijackTrip);
const extend = await rest(owner, "PATCH", `trips?id=eq.${trip.data.id}&select=id,lat`, { ends_at: new Date(Date.now() + 99 * 3600e3).toISOString() });
check(extend.status >= 400, "a trip can't be extended past its limit", extend);
const guess = await scan({ action: "trip", token: "0".repeat(36) }, ip);
check(guess.status === 404, "a wrong trip token finds nothing", guess);
await rest(owner, "PATCH", `trips?id=eq.${trip.data.id}&select=id,lat`, { stopped: true });
const ended = await scan({ action: "trip", token: trip.data.token }, ip);
check(ended.data.ended === true && !("lat" in ended.data), "after stopping, the position is no longer shared", ended);

// --- plate lockout
const lockIp = `203.0.113.${rnd()}`;
for (let i = 0; i < 5; i++) await scan({ action: "alert", code, kind: "other", plate_last4: "9999" }, lockIp);
const locked = await scan({ action: "alert", code, kind: "other", plate_last4: last4 }, lockIp);
check(locked.status === 429 && locked.data.error === "too_many_attempts", "5 wrong plate guesses lock the sender out", locked);

// --- deactivated tag
await rest(owner, "PATCH", `tags?code=eq.${code}`, { active: false });
const dead = await scan({ action: "lookup", code }, ip);
check(dead.status === 404, "deactivated tag stops working", dead);


// --- the stranger's language travels with the alert
{
  const owner2 = await signIn();
  const lp = `KA07LL${Math.floor(1000 + Math.random() * 8999)}`;
  const lv = await rest(owner2, "POST", "vehicles", { reg_number: lp, make: "Honda", model: "Amaze" });
  const lt = await rest(owner2, "POST", "tags", { vehicle_id: lv.data[0].id });
  const kn = await scan({ action: "alert", code: lt.data[0].code, kind: "other", plate_last4: lp.slice(-4), lang: "kn" }, "10.9.2.1");
  const bogus = await scan({ action: "alert", code: lt.data[0].code, kind: "other", plate_last4: lp.slice(-4), lang: "xx'; drop table alerts;--" }, "10.9.2.2");
  const none = await scan({ action: "alert", code: lt.data[0].code, kind: "other", plate_last4: lp.slice(-4) }, "10.9.2.3");
  check(kn.status === 200 && bogus.status === 200 && none.status === 200, "alerts accepted with and without a language", [kn, bogus, none]);
  const rows = await rest(owner2, "GET", "alerts?select=id,scanner_lang");
  const byId = Object.fromEntries(rows.data.map((r) => [r.id, r.scanner_lang]));
  check(byId[kn.data.alert_id] === "kn", "owner sees the stranger's language", rows);
  check(byId[bogus.data.alert_id] === "en" && byId[none.data.alert_id] === "en", "unknown or missing language falls back to English", rows);
}

// --- "the owner has seen your message"
{
  const o = await signIn();
  const other = await signIn();
  const sp = `KA08SS${Math.floor(1000 + Math.random() * 8999)}`;
  const sv = await rest(o, "POST", "vehicles", { reg_number: sp, make: "Maruti Suzuki", model: "Baleno" });
  const st = await rest(o, "POST", "tags", { vehicle_id: sv.data[0].id });
  const a = await scan({ action: "alert", code: st.data[0].code, kind: "blocking", plate_last4: sp.slice(-4) }, "10.9.3.1");
  const before = await scan({ action: "thread", alert_id: a.data.alert_id, token: a.data.token }, "10.9.3.2");
  check(before.data.seen === false, "a fresh alert is not marked seen", before);
  const stolen = await rest(other, "PATCH", `alerts?id=eq.${a.data.alert_id}`, { seen_at: new Date().toISOString() });
  const still = await scan({ action: "thread", alert_id: a.data.alert_id, token: a.data.token }, "10.9.3.3");
  check(still.data.seen === false, "another user cannot mark someone else's alert seen", [stolen, still]);
  const mark = await rest(o, "PATCH", `alerts?id=eq.${a.data.alert_id}`, { seen_at: new Date().toISOString() });
  check(mark.status < 300, "owner marks the alert seen", mark);
  const after = await scan({ action: "thread", alert_id: a.data.alert_id, token: a.data.token }, "10.9.3.4");
  check(after.data.seen === true, "the person at the car is told it was seen", after);
}

// --- more than one car per account
{
  const multi = await signIn();
  const a = await rest(multi, "POST", "vehicles", { reg_number: `KA05AA${Math.floor(1000 + Math.random() * 9000)}`, make: "Hyundai", model: "i20" });
  const b = await rest(multi, "POST", "vehicles", { reg_number: `KA05BB${Math.floor(1000 + Math.random() * 9000)}`, make: "Kia", model: "Seltos" });
  check(a.status === 201 && b.status === 201, "one account can own two cars", [a, b]);
  const ta = await rest(multi, "POST", "tags", { vehicle_id: a.data[0].id });
  const tb = await rest(multi, "POST", "tags", { vehicle_id: b.data[0].id });
  check(ta.status === 201 && tb.status === 201 && ta.data[0].code !== tb.data[0].code, "each car gets its own tag", [ta, tb]);
  const mine = await rest(multi, "GET", "vehicles?select=id");
  check(mine.data.length === 2, "owner sees both cars", mine);
}

// --- account deletion
{
  const goner = await signIn();
  const gv = await rest(goner, "POST", "vehicles", { reg_number: `KA09ZZ${Math.floor(1000 + Math.random() * 9000)}`, make: "Tata", model: "Nexon" });
  const gt = await rest(goner, "POST", "tags", { vehicle_id: gv.data[0].id });
  const del = await rest(goner, "POST", "rpc/delete_my_account", {});
  check(del.status < 300, "owner can delete their account", del);
  const after = await scan({ action: "lookup", code: gt.data[0].code }, "10.9.1.1");
  check(after.status === 404, "deleted account's tag stops resolving", after);
  const anonDel = await fetch(`${URL_}/rest/v1/rpc/delete_my_account`, { method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" }, body: "{}" });
  check(anonDel.status >= 400, "anon key cannot call delete_my_account", anonDel.status);
}

console.log(`\n${passed} checks passed`);
