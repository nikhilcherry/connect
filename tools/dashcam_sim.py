"""A stand-in dashcam: serves a video as a live MJPEG-over-HTTP stream, the way many Wi-Fi dashcams and
phone-as-camera apps serve their live view. For testing and demos the app's "Connect a dashcam" without a dashcam.

  python dashcam_sim.py clip.mp4                 # http://<this computer>:8190/video
  python dashcam_sim.py clip.mp4 --port 8190 --fps 15 --width 1280

Phone on USB:  adb reverse tcp:8190 tcp:8190   then in the app use  http://127.0.0.1:8190/video
Phone on Wi-Fi: use this computer's address, for example  http://192.168.1.20:8190/video

Needs OpenCV (pip install opencv-python). Plain HTTP, no sign-in: run it on a trusted network only.
"""
import argparse
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cv2


class Source:
    """Decodes the video once, in real time and in a loop, and keeps the newest JPEG for every viewer."""

    def __init__(self, path, fps, width, quality):
        self.path, self.fps, self.width, self.quality = path, fps, width, quality
        self.jpeg = b""
        self.counter = 0
        self.cond = threading.Condition()
        self.alive = True

    def run(self):
        cap = cv2.VideoCapture(self.path)
        if not cap.isOpened():
            sys.exit("cannot open " + self.path)
        step = max(1, round((cap.get(cv2.CAP_PROP_FPS) or 30) / self.fps))
        period = 1.0 / self.fps
        i = 0
        nxt = time.time()
        while self.alive:
            ok, frame = cap.read()
            if not ok:
                cap.set(cv2.CAP_PROP_POS_FRAMES, 0)  # loop
                i = 0
                continue
            i += 1
            if i % step:
                continue
            h, w = frame.shape[:2]
            if self.width and w > self.width:
                frame = cv2.resize(frame, (self.width, int(h * self.width / w)), interpolation=cv2.INTER_AREA)
            ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, self.quality])
            if ok:
                with self.cond:
                    self.jpeg = buf.tobytes()
                    self.counter += 1
                    self.cond.notify_all()
            nxt += period
            time.sleep(max(0.0, nxt - time.time()))


def make_handler(src):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def log_message(self, fmt, *a):
            sys.stderr.write("%s\n" % (fmt % a))

        def do_GET(self):
            if self.path.split("?")[0] in ("/snapshot.jpg", "/shot.jpg"):
                with src.cond:
                    data = src.jpeg
                self.send_response(200 if data else 503)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if self.path.split("?")[0] not in ("/", "/video", "/stream", "/mjpeg"):
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            seen = -1
            try:
                while src.alive:
                    with src.cond:
                        while src.counter == seen and src.alive:
                            src.cond.wait(1.0)
                        data, seen = src.jpeg, src.counter
                    if not data:
                        continue
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(data))
                    self.wfile.write(data)
                    self.wfile.write(b"\r\n")
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass

    return H


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("video")
    ap.add_argument("--port", type=int, default=8190)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--fps", type=float, default=15)
    ap.add_argument("--width", type=int, default=1280, help="shrink frames wider than this (0 keeps them)")
    ap.add_argument("--quality", type=int, default=82)
    a = ap.parse_args()
    src = Source(a.video, a.fps, a.width, a.quality)
    threading.Thread(target=src.run, daemon=True).start()
    srv = ThreadingHTTPServer((a.host, a.port), make_handler(src))
    print("Fake dashcam on http://%s:%d/video  (Ctrl+C to stop)" % (a.host, a.port))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    src.alive = False


if __name__ == "__main__":
    main()
