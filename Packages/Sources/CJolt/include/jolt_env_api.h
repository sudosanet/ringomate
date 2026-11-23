// キャラクターの居場所の 2 次元の物理。画面の空間（左下が原点、y 上、MMD 単位）。
#ifndef JOLT_ENV_API_H
#define JOLT_ENV_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct jolt_env jolt_env;

/// `radius` は体の幅の半分、`height` は足元からのカプセルの高さ。
jolt_env *jolt_env_create(float radius, float height, float gravity, float friction, float restitution, float damping);
void jolt_env_destroy(jolt_env *e);
void jolt_env_set_stage(jolt_env *e, float width, float ground);
/// `surfaces` は面ごとに 左端・右端・上端。`ignore` 番目はすり抜ける（−1 ならなし）。
void jolt_env_set_platforms(jolt_env *e, const float *surfaces, int32_t count, int32_t ignore);
void jolt_env_place(jolt_env *e, float x, float y, float vx, float vy);
/// `walk` が有限なら接地中の横の速度をそれにする。
void jolt_env_step(jolt_env *e, float dt, int32_t steps, float walk);
/// `support`: 足場の番号、−1 は床、−2 は空中。
void jolt_env_get(const jolt_env *e, float pos[2], float vel[2], int32_t *support);

#ifdef __cplusplus
}
#endif

#endif
