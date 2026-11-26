#pragma once

#ifdef __cplusplus
extern "C" {
#endif

double wr_settle_pos(double u, double curve);
double wr_settle_target(double now, double still, double dur, double travel);
double wr_settle_time(double wall, double end, double settle, double curve);

#ifdef __cplusplus
}
#endif
