#include "settle.h"

#include <math.h>

double wr_settle_pos(double u, double curve) {
	if (u <= 0) return 0;
	if (u >= 1) return 1;
	return 1 - pow(1 - u, curve);
}

double wr_settle_target(double now, double still, double dur, double travel) {
	double want = now + travel;
	if (dur <= 0) return still >= want ? still : want;
	double n = ceil((want - still) / dur - 1e-9);
	if (n < 0) n = 0;
	return still + n * dur;
}

double wr_settle_time(double wall, double end, double settle, double curve) {
	double travel = settle / curve;
	double at = end - travel;
	if (wall <= at) return wall;
	return at + travel * wr_settle_pos((wall - at) / settle, curve);
}
