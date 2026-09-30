"""Blender addon: send the current scene to Apple Vision Pro via Spatial Preview.

Install once (see README.md), then use the
"Spatial Preview" tab in the 3D viewport sidebar (press N). No console, no file picking.

Headless export, when you want just the USD file:

blender -b scene.blend -P spatial_preview_bridge.py -- /path/out.usdc
"""

import json
import os
import re
import shutil
import socket
import sys
import textwrap
import time

import bpy
import bpy.utils.previews
from bpy.app.handlers import persistent

bl_info = {
    "name": "Spatial Preview Bridge",
    "author": "Adrian",
    "version": (0, 4, 0),
    "blender": (5, 2, 0),
    "location": "View3D > Sidebar > Spatial Preview",
    "description": "Send the scene to Apple Vision Pro through Spatial Preview",
    "category": "Import-Export",
}

HOST = "127.0.0.1"
PORT = 8767

# The largest single mesh verified on device is the 401,956-vertex grid from
# make_bench_scenes.py, which displayed correctly. RoboSoldier.glb's 894,441-vertex mesh
# did not - and it took the rest of the scene with it: every other model arrived as a
# small placeholder cube while that one object consumed whatever budget Apple applies.
# So this warns about one heavy object, and about what it does to its neighbours.
VERIFIED_SINGLE_MESH = 401_956

# The heaviest whole scene verified on device: 1,150,161 vertices / 102 MB, which arrived
# intact but took 38.6 s. Above this, nothing has been measured. Apple documents no size
# limit and reports no size error, so this is deliberately not phrased as "too big for
# Spatial Preview" - it is the edge of what is known, which is the only honest thing to
# warn about.
VERIFIED_SCENE_TOTAL = 1_150_161

# How long to wait for the headset to accept a scene. Generous on purpose: Apple's
# processing time grows faster than the file does.
SEND_TIMEOUT = 180.0

# The one place a send is written. macOS's cache folder, not the repo: an addon that
# was copied rather than symlinked would otherwise write into Blender's addons folder,
# and a repo in iCloud Drive would upload every send. Only the latest send is kept.
EXPORT_DIR = os.path.expanduser("~/Library/Caches/SpatialPreviewBridge/scene")


def _fresh_export_dir():
    """Empty the export folder and hand it back. Emptied rather than reused as-is, so no
    texture from the previous model lingers, nor the -optimized copy Apple writes
    next to a heavy scene."""
    shutil.rmtree(EXPORT_DIR, ignore_errors=True)
    os.makedirs(EXPORT_DIR, exist_ok=True)
    return EXPORT_DIR


def _scene_materials():
    """Only materials on objects the exporter will write - visible ones. bpy.data.materials
    is global, and a warning about a material nobody will see is just noise."""
    materials = []
    for obj in bpy.context.scene.objects:
        if not obj.visible_get():
            continue
        for slot in obj.material_slots:
            if slot.material is not None and slot.material not in materials:
                materials.append(slot.material)
    return materials


def _scene_images():
    """Image datablocks reachable from the scene's materials, in a stable order."""
    images = []
    for material in _scene_materials():
        if not material.use_nodes or material.node_tree is None:
            continue
        for node in material.node_tree.nodes:
            if node.bl_idname == 'ShaderNodeTexImage' and node.image is not None:
                if node.image not in images:
                    images.append(node.image)
    return images


_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".tga", ".tif", ".tiff", ".bmp", ".exr",
               ".hdr", ".webp")


def _export_key(name):
    """Near enough to the filename Blender will write for an image datablock to spot a
    collision: it drops its own `.001` duplicate suffix and any extension already in the
    name, then puts the real extension back on. `Image_0` and `Image_0.jpg` both end up
    as `Image_0.jpg`."""
    stem = re.sub(r"\.\d{3}$", "", name)
    low = stem.lower()
    for ext in _IMAGE_EXTS:
        if low.endswith(ext):
            stem = stem[:-len(ext)]
            break
    return stem.lower()


def _unique_image_names(restore):
    """Rename image datablocks that would export to the same filename, for the duration
    of an export.

    Two datablocks can collapse onto one filename, and the second one written then wins -
    so both materials point at the same file and one model wears the other's textures.
    glTF and FBX imports make this common, because each file names its maps `Image_0`,
    `Image_1`, and so on, and two imports collide on sight. Per-send directories do not
    help: this is a collision inside one export.

    Appends (image, old name) to `restore` as it goes, so a failure part-way can still be
    undone. Returns the descriptions.
    """
    counts, renamed = {}, []
    # A linked image cannot be renamed, so linked ones are counted first and keep their
    # names; a local image that collides with one is the one renamed.
    for image in sorted(_scene_images(), key=lambda i: i.library is None):
        key = _export_key(image.name)
        counts[key] = counts.get(key, 0) + 1
        if counts[key] == 1:
            continue
        old = image.name
        image.name = "%s_spb%d" % (old, counts[key])
        restore.append((image, old))
        renamed.append("%s -> %s" % (old, image.name))
    return renamed


def _short(n, digits=1):
    """1,513,008 -> 1.5M, 401,956 -> 402k. A notice is read at a glance, not audited."""
    if n >= 999_500:
        return "%.*fM" % (digits, n / 1e6)
    if n >= 1000:
        return "%.*fk" % (digits - 1, n / 1e3)
    return str(n)


def _visible_meshes():
    """(vertex count, name) for what the exporter will write: meshes visible in the
    viewport, evaluated with their modifiers. Evaluated, because the size warning tells
    you to add a Decimate modifier, and a count that ignored modifiers kept warning after
    you did."""
    deps = bpy.context.evaluated_depsgraph_get()
    return [(len(o.evaluated_get(deps).data.vertices), o.name)
            for o in bpy.context.scene.objects if o.type == 'MESH' and o.visible_get()]


def size_notice():
    """The size notice, or None. Kept apart from preflight() because it follows the scene
    live, while the other warnings are checked when you send.

    Worded as a limitation, not a failure: the send works, and the likely symptoms are
    slowness and placeholder cubes. One notice, whichever limit was crossed.
    """
    heavy = _visible_meshes()
    total = sum(v for v, _ in heavy)
    if total > VERIFIED_SCENE_TOTAL or any(v > VERIFIED_SINGLE_MESH for v, _ in heavy):
        return ("Vertex count over Spatial Preview capacity (total: %s verts)\n"
                "May load slowly or show placeholder cubes;\n"
                "a Decimate modifier may help" % _short(total))
    return None


def preflight():
    """Problems that show up on the headset but not in Blender. Returns a list of lines.

    Never blocks a send - these are all cases where the export succeeds and the result
    simply looks wrong, which is much harder to diagnose after the fact than before.
    """
    warnings = []
    materials = _scene_materials()

    # Several UV sets per mesh is fine: every set is exported and each texture's reader
    # points at the right one. Verified 2026-09-17 - an earlier warning here was wrong.

    flat = [m.name for m in materials
            if not m.use_nodes or m.node_tree is None
            or not any(n.bl_idname == 'ShaderNodeBsdfPrincipled' for n in m.node_tree.nodes)]
    if flat:
        warnings.append(
            "material(s) with no Principled BSDF may not convert to UsdPreviewSurface: "
            + ", ".join(flat[:3]))

    # One object being far heavier than everything else is not a Blender problem and
    # exports perfectly - it goes wrong inside Apple's processing, where nothing reports
    # it. Said here because this is the last point at which it is cheap to act on.
    missing = []
    for mat in materials:
        if not mat.use_nodes or mat.node_tree is None:
            continue
        for node in mat.node_tree.nodes:
            if node.bl_idname != 'ShaderNodeTexImage':
                continue
            image = node.image
            if image is None:
                missing.append("%s (empty image node)" % mat.name)
            elif (image.source == 'FILE' and not image.packed_file
                  and not os.path.exists(bpy.path.abspath(image.filepath))):
                missing.append(image.name)
    if missing:
        warnings.append("image file(s) not found, will export as flat colour: "
                        + ", ".join(dict.fromkeys(missing))[:120])

    return warnings


def _bypass_blank_uv_nodes(restore):
    """Unhook every blank UV Map node for the duration of an export.

    A UV Map node with an empty field means "the active UV map" and renders correctly in
    Blender, but the exporter writes its reader as the primvar `_`, which no mesh has.
    The texture then samples a UV set that does not exist and the object arrives as one
    flat colour - the base material with none of its detail.

    Unhooking rather than naming the layer, because naming it is a guess that can be
    wrong: the exporter writes `st` only when the name matches the active render layer of
    the mesh it happens to be exporting at the time, and meshes sharing a material can
    have differently named layers. A texture with nothing wired to its Vector input means
    exactly what the blank node means - use the active UV map - and that case is the one
    the exporter always gets right, whatever the layer is called.

    Appends (tree, output, to_socket) to `restore` as it goes, so a failure part-way can
    still be undone. Returns the affected material names.
    """
    repaired = []
    for material in _scene_materials():
        if not material.use_nodes or material.node_tree is None:
            continue
        tree = material.node_tree
        touched = False
        for node in tree.nodes:
            if node.bl_idname != 'ShaderNodeUVMap' or node.uv_map:
                continue
            for output in node.outputs:
                for link in list(output.links):
                    restore.append((tree, output, link.to_socket))
                    tree.links.remove(link)
                    touched = True
        if touched:
            repaired.append(material.name)
    return repaired


def export_stage(path=None):
    """Write the current scene to USD.

    Returns (path, seconds, mesh_count, verts, repaired materials, renamed images).
    """
    if path is None:
        path = os.path.join(_fresh_export_dir(), "scene.usdc")
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)

    # Both preparations change the user's file, so both run inside the try: a rename that
    # fails (a linked image, say) must still put every link and name back.
    restore, renames = [], []
    try:
        repaired = _bypass_blank_uv_nodes(restore)
        renamed = _unique_image_names(renames)
        t0 = time.time()
        bpy.ops.wm.usd_export(
            filepath=path,
            export_textures_mode='NEW',
            # Off by default, which means a texture whose name already exists next to
            # the USD is silently kept - so a second model called its map Image_0.jpg
            # too and ships wearing the first model's textures. Every send is its own
            # directory now, but leave this on: it is the difference between wrong
            # pixels and right ones.
            overwrite_textures=True,
            generate_preview_surface=True,
            relative_paths=True,
            # On by default, which exports the Blender world as a dome light. A plain
            # dark world background then becomes the only light in the scene, and the
            # model arrives black however good its textures are. The headset lights the
            # model against the actual room, so it needs no light from us.
            convert_world_material=False,
            # Defaults to RENDER, which decides visibility by the camera icon and
            # evaluates modifiers at their render settings - so an object hidden with
            # H still went to the headset. The viewport is what the user is looking at.
            evaluation_mode='VIEWPORT',
        )
    finally:
        # The scene must come back exactly as the user left it, export or no export.
        for tree, output, to_socket in restore:
            tree.links.new(output, to_socket)
        for image, old_name in renames:
            image.name = old_name
    elapsed = time.time() - t0

    meshes = _visible_meshes()
    return path, elapsed, len(meshes), sum(v for v, _ in meshes), repaired, renamed


# --- talking to the bridge app ----------------------------------------------

def send(message, timeout=2.0):
    """One short line of JSON to the bridge app. Returns (reply dict, error), where the
    error is a (line, detail) pair for the sidebar.

    Only one of the two return values is ever set. The bridge does not answer until it
    knows the outcome, so the reply is the whole truth about what happened.
    """
    try:
        with socket.create_connection((HOST, PORT), timeout=timeout) as sock:
            sock.sendall((json.dumps(message) + "\n").encode("utf-8"))
            sock.settimeout(timeout)
            buffer = b""
            while b"\n" not in buffer:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buffer += chunk
            if not buffer:
                return None, ("bridge app closed without answering",
                              "check the bridge app window")
            return json.loads(buffer.split(b"\n")[0].decode("utf-8")), None
    except ConnectionRefusedError:
        return None, ("bridge app is not running", "open SpatialPreviewBridge.app")
    except socket.timeout:
        # A big scene can hold Apple busy for well over a minute. Saying so beats a bare
        # timeout, which reads as a failure when the headset is probably still loading.
        return None, ("the headset is taking longer than %ds" % int(timeout),
                      "check the bridge app window")
    except ConnectionResetError:
        # The app is there but dropped the connection. Restarting it is the cure, and
        # saying "not running" here sent the user looking for a thing that was running.
        return None, ("bridge app stopped answering", "quit and reopen it")
    except OSError as exc:
        return None, ("cannot reach the bridge app", "%s" % exc)
    except ValueError as exc:
        return None, ("unreadable reply from the bridge app", "%s" % exc)


# What the panel shows: the outcome of the last send, as the bridge reported it. A
# record of the past, never a live reading - Blender hears from the bridge only when you
# press a button, and whether the headset still shows the scene is the bridge window's
# job. `changed` is the one live part, and Blender tells us that for free.
_status = {"outcome": "", "line": "", "detail": "", "level": 'NONE', "size": None,
           "warnings": [], "sent": False, "changed": False, "shown": frozenset(),
           "settling": False}


def _tag_redraw():
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type == 'VIEW_3D':
                area.tag_redraw()


def _set_status(outcome, line, detail="", level='NONE'):
    if (outcome, line, detail, level) == (_status["outcome"], _status["line"],
                                          _status["detail"], _status["level"]):
        return
    _status.update(outcome=outcome, line=line, detail=detail, level=level)
    _tag_redraw()


def _note_reply(reply):
    """Turn a bridge reply into an outcome and one line a human can act on."""
    on = bool(reply.get("running"))
    outcome = "arrived" if on else "not arrived"
    mb = reply.get("bytes", 0) / 1e6
    size = "%s vertices - %s objects - %s MB" % (
        _short(reply.get("vertices", 0)),
        f"{reply.get('meshes', 0):,}",
        "%.0f" % mb if mb >= 10 else "%.1f" % mb)

    problem = reply.get("problem") or ""
    if problem:
        _set_status(outcome, problem, reply.get("hint", ""), 'ERROR')
        return

    # The scene is on the headset but will not look right - worth saying so loudly,
    # because the headset gives no hint that anything is wrong.
    warning = reply.get("warning") or ""
    if warning:
        _set_status(outcome, "check the textures", warning, 'ERROR')
        return

    if on:
        _set_status(outcome, "", size)
    else:
        _set_status(outcome, "the headset is not showing it", size, 'ERROR')


def _shown_warnings():
    return ([_status["size"]] if _status["size"] else []) + _status["warnings"]


def _refresh_size_notice():
    notice = size_notice()
    if notice != _status["size"]:
        _status["size"] = notice
        _tag_redraw()


def _shown_objects():
    return frozenset(o.name for o in bpy.context.scene.objects if o.visible_get())


def _mark_changed(depsgraph):
    """Note that the headset copy is out of date. Selecting and hiding both arrive as a
    bare Scene update with no flags, so hiding is caught by comparing what is visible.
    The export itself flags every object, hence `settling` just after a send."""
    if not _status["sent"] or _status["changed"] or _status["settling"]:
        return
    if (any(u.is_updated_geometry or u.is_updated_transform or u.is_updated_shading
            for u in depsgraph.updates) or _shown_objects() != _status["shown"]):
        _status["changed"] = True
        _tag_redraw()


def _settled():
    _status["settling"] = False
    return None


# Blender says when the scene changed, so the panel follows it with no timer and no
# polling: the size notice appears on import and goes on delete or decimate - before any
# send - and "changed since" appears on any edit after one. The size check is read-only
# and costs about 0.2 ms; moving things is skipped there, as it cannot change a count.
@persistent
def _on_change(scene, depsgraph):
    _mark_changed(depsgraph)
    if all(u.is_updated_transform and not u.is_updated_geometry
           and isinstance(u.id, bpy.types.Object) for u in depsgraph.updates):
        return
    _refresh_size_notice()


@persistent
def _on_load(_):
    if _status["sent"]:
        _status["changed"] = True
    _refresh_size_notice()


class SPB_OT_stream(bpy.types.Operator):
    bl_idname = "spb.stream"
    bl_label = "Send to Vision Pro"
    bl_description = "Export the scene and open it on the headset"

    def execute(self, context):
        _status["warnings"] = preflight()
        _refresh_size_notice()
        for warning in _shown_warnings():
            self.report({'WARNING'}, warning.replace("\n", " "))

        # Always re-export, into an emptied folder. A reused file silently keeps objects
        # that have since been deleted in Blender, and a reused folder silently keeps
        # the previous model's textures - neither is visible from the headset.
        _status["settling"] = True
        try:
            path, elapsed, meshes, verts, repaired, renamed = export_stage()
        except Exception:
            # No send follows, so no timer would ever clear it, and "Scene changed
            # since" would stay off until the next send that works.
            _status["settling"] = False
            raise
        self.report({'INFO'}, "Exported %d meshes / %d verts in %.1fs" % (meshes, verts, elapsed))
        if repaired:
            self.report({'INFO'}, "Bypassed a blank UV Map node in %d material(s), which "
                                  "would otherwise arrive untextured: %s"
                                  % (len(repaired), ", ".join(repaired[:4])))
        if renamed:
            self.report({'INFO'}, "Renamed %d image(s) for the export, which would "
                                  "otherwise have overwritten each other: %s"
                                  % (len(renamed), ", ".join(renamed[:4])))

        # The bridge answers only once the headset has the scene or has refused it, so
        # there is one question and one truthful answer and no polling loop. The wait has
        # to cover Apple's processing, which is not linear in scene size: 27 MB took 2 s
        # and 102 MB took 38.6 s on the same machine. Blender is unresponsive until it
        # returns, which is the price of the answer being true.
        reply, error = send({"cmd": "open_and_start", "path": path}, timeout=SEND_TIMEOUT)
        _status.update(sent=True, changed=False, shown=_shown_objects())
        # The export's own updates land after this returns; a moment later nobody has
        # had time to edit anything yet. One-shot, not a polling timer.
        bpy.app.timers.register(_settled, first_interval=0.5)
        if error:
            _set_status("not arrived", error[0], error[1], 'ERROR')
            self.report({'ERROR'}, "%s - %s" % error)
            return {'CANCELLED'}

        _note_reply(reply)
        return {'FINISHED'}


class SPB_OT_stop(bpy.types.Operator):
    bl_idname = "spb.stop"
    bl_label = "Close on Headset"
    bl_description = "Close the preview on the headset"

    def execute(self, context):
        reply, error = send({"cmd": "close"})
        if error:
            # The close never reached the bridge, so the headset may well still show it.
            _set_status(_status["outcome"], error[0], error[1], 'ERROR')
            self.report({'ERROR'}, "%s - %s" % error)
            return {'CANCELLED'}
        _set_status("closed", "")
        return {'FINISHED'}


class SPB_PT_panel(bpy.types.Panel):
    bl_label = "Spatial Preview"
    bl_idname = "SPB_PT_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Spatial Preview"

    def draw(self, context):
        layout = self.layout
        layout.operator("spb.stream", icon='PLAY')
        layout.operator("spb.stop", icon='PANEL_CLOSE')

        box = layout.box()
        row = box.row()
        row.label(text="Last send" if _status["sent"] else "Nothing sent yet")
        if _status["sent"] and _status["outcome"]:
            state = row.row()
            state.alignment = 'RIGHT'
            state.label(text=_status["outcome"],
                        icon={"arrived": 'CHECKMARK', "closed": 'PANEL_CLOSE'}
                        .get(_status["outcome"], 'CANCEL'))

        if _status["line"]:
            line = box.row()
            line.alert = _status["level"] == 'ERROR'
            line.label(text=_status["line"])
        if _status["detail"]:
            box.label(text=_status["detail"])
        if _status["changed"] and _status["outcome"] == "arrived":
            box.label(text="Scene changed since - send again", icon='INFO')

        # Labels never wrap; a long one is clipped in the middle, which is where the
        # number was. Region width is in device pixels and ui_scale is the whole DPI
        # factor (2 on a retina Mac); about 7 logical px per character - digits are wider
        # than letters, and a warning is mostly digits - minus the icon.
        logical = context.region.width / context.preferences.system.ui_scale
        width = max(20, int((logical - 40) / 7.2))
        yellow = _icons["spb_warning"].icon_id if _icons else 0
        for warning in _shown_warnings():
            col = layout.column(align=True)
            pieces = [p for line in warning.split("\n") for p in textwrap.wrap(line, width)]
            for i, piece in enumerate(pieces):
                if i == 0 and yellow:
                    col.label(text=piece, icon_value=yellow)
                else:
                    col.label(text=piece, icon='ERROR' if i == 0 else 'BLANK1')


_CLASSES = (SPB_OT_stream, SPB_OT_stop, SPB_PT_panel)

_icons = None


def _warning_pixels(n=64):
    """A yellow triangle with a dark exclamation mark, as RGBA floats, bottom row first.

    Blender labels are plain or red, and red reads as "this failed". These notices are
    a limitation being stated honestly, not a failure - so they get a yellow icon of
    their own. Drawn here rather than shipped as an image, so the addon stays one file.
    """
    pixels = []
    for y in range(n):
        t = (y - 2) / (n - 5)                        # 0 on the base, 1 at the apex
        for x in range(n):
            dx = abs(x + 0.5 - n / 2)
            inside = 0 <= t <= 1 and dx <= (1 - t) * (n / 2 - 2)
            mark = dx <= n / 18 and (0.12 <= t <= 0.22 or 0.32 <= t <= 0.66)
            pixels += ((0.12, 0.1, 0.04, 1.0) if inside and mark
                       else (1.0, 0.77, 0.2, 1.0) if inside else (0.0, 0.0, 0.0, 0.0))
    return pixels


def register():
    global _icons
    _icons = bpy.utils.previews.new()
    icon = _icons.new("spb_warning")
    icon.image_size = (64, 64)
    icon.image_pixels_float = _warning_pixels(64)
    for cls in _CLASSES:
        bpy.utils.register_class(cls)
    bpy.app.handlers.depsgraph_update_post.append(_on_change)
    bpy.app.handlers.load_post.append(_on_load)


def unregister():
    global _icons
    bpy.app.handlers.depsgraph_update_post.remove(_on_change)
    bpy.app.handlers.load_post.remove(_on_load)
    for cls in reversed(_CLASSES):
        bpy.utils.unregister_class(cls)
    bpy.utils.previews.remove(_icons)
    _icons = None


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    for warning in [size_notice()] + preflight():
        if warning:
            print("[spatial_preview_bridge] warning: %s" % warning.replace("\n", " "))
    path, elapsed, meshes, verts, repaired, renamed = export_stage(argv[0] if argv else None)
    print("[spatial_preview_bridge] %s" % path)
    print("[spatial_preview_bridge] %d meshes, %d verts, %.2fs" % (meshes, verts, elapsed))
    if repaired:
        print("[spatial_preview_bridge] blank UV Map node bypassed for: %s"
              % ", ".join(repaired))
    if renamed:
        print("[spatial_preview_bridge] images renamed to avoid collisions: %s"
              % ", ".join(renamed))
