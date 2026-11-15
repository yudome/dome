#pragma once

#include <functional>

struct wl_display;
struct wl_seat;
struct wl_surface;

class WaylandPointerLock {
public:
	struct Private;

	WaylandPointerLock();
	~WaylandPointerLock();

	void setSurface(wl_display *display, wl_seat *seat, wl_surface *surface);
	bool lock(bool on);
	bool locked() const;
	void onMotion(std::function<void(double, double)> handler);
	void onLost(std::function<void()> handler);

private:
	Private *d;
};
