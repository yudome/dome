#include "pointerlock.h"

#include <wayland-client.h>

#include <cstring>

#include "pointer-constraints-client-protocol.h"
#include "relative-pointer-client-protocol.h"

struct WaylandPointerLock::Private {
	wl_display *display = nullptr;
	wl_registry *registry = nullptr;
	wl_seat *seat = nullptr;
	wl_surface *surface = nullptr;
	wl_pointer *pointer = nullptr;
	zwp_pointer_constraints_v1 *constraints = nullptr;
	zwp_relative_pointer_manager_v1 *relativeManager = nullptr;
	zwp_locked_pointer_v1 *lockedPointer = nullptr;
	zwp_relative_pointer_v1 *relative = nullptr;
	bool locked = false;
	std::function<void(double, double)> motion;
	std::function<void()> lost;

	void release() {
		if (relative) zwp_relative_pointer_v1_destroy(relative);
		if (lockedPointer) zwp_locked_pointer_v1_destroy(lockedPointer);
		relative = nullptr;
		lockedPointer = nullptr;
		locked = false;
	}
};

namespace {

void onRelative(void *data, zwp_relative_pointer_v1 *, uint32_t, uint32_t, wl_fixed_t, wl_fixed_t, wl_fixed_t dx, wl_fixed_t dy) {
	auto *d = static_cast<WaylandPointerLock::Private *>(data);
	if (d->locked && d->motion) d->motion(wl_fixed_to_double(dx), wl_fixed_to_double(dy));
}

const zwp_relative_pointer_v1_listener relativeListener = {onRelative};

void onLocked(void *data, zwp_locked_pointer_v1 *) {
	static_cast<WaylandPointerLock::Private *>(data)->locked = true;
}

void onUnlocked(void *data, zwp_locked_pointer_v1 *) {
	auto *d = static_cast<WaylandPointerLock::Private *>(data);
	const bool was = d->lockedPointer != nullptr;
	d->release();
	if (was && d->lost) d->lost();
}

const zwp_locked_pointer_v1_listener lockedListener = {onLocked, onUnlocked};

void onGlobal(void *data, wl_registry *registry, uint32_t name, const char *interface, uint32_t) {
	auto *d = static_cast<WaylandPointerLock::Private *>(data);
	if (strcmp(interface, zwp_pointer_constraints_v1_interface.name) == 0) {
		d->constraints = static_cast<zwp_pointer_constraints_v1 *>(wl_registry_bind(registry, name, &zwp_pointer_constraints_v1_interface, 1));
	} else if (strcmp(interface, zwp_relative_pointer_manager_v1_interface.name) == 0) {
		d->relativeManager = static_cast<zwp_relative_pointer_manager_v1 *>(wl_registry_bind(registry, name, &zwp_relative_pointer_manager_v1_interface, 1));
	}
}

void onGlobalRemove(void *, wl_registry *, uint32_t) {}

const wl_registry_listener registryListener = {onGlobal, onGlobalRemove};

} // namespace

WaylandPointerLock::WaylandPointerLock() : d(new Private) {}

WaylandPointerLock::~WaylandPointerLock() {
	d->release();
	if (d->pointer) wl_pointer_release(d->pointer);
	if (d->relativeManager) zwp_relative_pointer_manager_v1_destroy(d->relativeManager);
	if (d->constraints) zwp_pointer_constraints_v1_destroy(d->constraints);
	if (d->registry) wl_registry_destroy(d->registry);
	delete d;
}

void WaylandPointerLock::setSurface(wl_display *display, wl_seat *seat, wl_surface *surface) {
	d->display = display;
	d->seat = seat;
	d->surface = surface;
}

bool WaylandPointerLock::lock(bool on) {
	if (!on) {
		d->release();
		if (d->display) wl_display_flush(d->display);
		return true;
	}
	if (d->lockedPointer) return true;
	if (!d->display || !d->seat || !d->surface) return false;

	if (!d->registry) {
		d->registry = wl_display_get_registry(d->display);
		wl_registry_add_listener(d->registry, &registryListener, d);
		wl_display_roundtrip(d->display);
	}
	if (!d->constraints || !d->relativeManager) return false;
	if (!d->pointer) d->pointer = wl_seat_get_pointer(d->seat);
	if (!d->pointer) return false;

	d->lockedPointer = zwp_pointer_constraints_v1_lock_pointer(d->constraints, d->surface, d->pointer, nullptr,
	                                                           ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_ONESHOT);
	zwp_locked_pointer_v1_add_listener(d->lockedPointer, &lockedListener, d);
	d->relative = zwp_relative_pointer_manager_v1_get_relative_pointer(d->relativeManager, d->pointer);
	zwp_relative_pointer_v1_add_listener(d->relative, &relativeListener, d);
	wl_display_flush(d->display);
	return true;
}

bool WaylandPointerLock::locked() const {
	return d->locked;
}

void WaylandPointerLock::onMotion(std::function<void(double, double)> handler) {
	d->motion = std::move(handler);
}

void WaylandPointerLock::onLost(std::function<void()> handler) {
	d->lost = std::move(handler);
}
