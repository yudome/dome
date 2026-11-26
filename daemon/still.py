import json, os, subprocess, sys, tempfile
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk


def yudae(*args):
    return json.loads(subprocess.run(["yudae", "--json", *args], capture_output=True, text=True, check=True).stdout)


def main(app):
    path = sys.argv[1] if len(sys.argv) > 1 else yudae("state")["wallpaper"]["active"]
    strip = yudae("call", "wallpaper", "filmstrip", json.dumps({"path": path}))
    fps = strip["fps"] or 30
    last = max(0, strip["duration"] - 1 / fps)
    shot = os.path.join(tempfile.mkdtemp(), "frame.png")

    picture = Gtk.Picture(vexpand=True)
    scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, last, 1 / fps)
    scale.set_draw_value(True)
    scale.set_digits(3)

    def show(_=None):
        t = scale.get_value()
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{t:.4f}", "-i", path, "-frames:v", "1", "-vf", "scale=960:-2", shot])
        picture.set_filename(None)
        picture.set_filename(shot)

    def step(frames):
        return lambda _: scale.set_value(min(last, max(0, round(scale.get_value() * fps + frames) / fps)))

    def save(_):
        yudae("call", "wallpaper", "frame", json.dumps({"path": path, "t": scale.get_value()}))
        window.close()

    row = Gtk.Box(spacing=6)
    for label, action in (("-1s", step(-fps)), ("-1 frame", step(-1)), ("+1 frame", step(1)), ("+1s", step(fps)), ("Save", save)):
        button = Gtk.Button(label=label)
        button.connect("clicked", action)
        row.append(button)

    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    for child in (picture, scale, row):
        box.append(child)
    window = Gtk.ApplicationWindow(application=app, title="Still frame", default_width=1000, default_height=700, child=box)
    scale.connect("value-changed", show)
    scale.set_value(strip["still"])
    show()
    window.present()


app = Gtk.Application()
app.connect("activate", main)
app.run([])
