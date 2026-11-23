// 長さは MMD 単位（中で m へ、1 単位 = 0.08m）。回転は四元数（x, y, z, w）。
#ifndef JOLT_PUPPET_API_H
#define JOLT_PUPPET_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct jolt_puppet_world jolt_puppet_world;

typedef enum {
    JOLT_PUPPET_SPHERE = 0,  // size[0] = 半径
    JOLT_PUPPET_BOX = 1,     // size = 半分の大きさ
    JOLT_PUPPET_CAPSULE = 2  // size[0] = 半径、size[1] = 円柱の長さ（Y 軸）
} jolt_puppet_shape;

typedef struct {
    int32_t shape;
    float size[3];
    float position[3];
    float rotation[4];
    float mass;             // 0 ならキネマティック
    float linear_damping;   // PMX の値
    float angular_damping;
    float friction;
    float restitution;
    uint16_t group;         // 1 << PMX の番号
    uint16_t mask;
    int32_t ccd;
} jolt_puppet_body_desc;

typedef struct {
    int32_t body_a;
    int32_t body_b;
    float position[3];
    float rotation[4];      // PMX のオイラー角 YXZ から
    float translation_lower[3];
    float translation_upper[3];
    float rotation_lower[3];  // 下限 > 上限は自由（PMX と同じ）
    float rotation_upper[3];
    float spring_translation[3];
    float spring_rotation[3];
    int32_t side;           // 1 なら親子でない剛体どうしの横のつなぎ
} jolt_puppet_joint_desc;

/// 0 の欄は既定。
typedef struct {
    float spring_frequency_scale;  // Hz = この値 × √(PMX のばね)
    float spring_frequency_min;
    float spring_frequency_max;
    float spring_damping;          // 減衰比（1 = 臨界）
    float max_angular_velocity;    // rad/s
    float max_linear_velocity;     // MMD 単位/s
    float inertia_multiplier;
    float penetration_slop;        // m
    float speculative_distance;    // m
    int32_t velocity_steps;
    int32_t position_steps;
    int32_t threads;               // 0 なら 1 本
} jolt_puppet_tuning;

/// 剛体とジョイントを足してから `jolt_puppet_world_finish` を呼ぶ。失敗なら NULL。
jolt_puppet_world *jolt_puppet_world_create(const jolt_puppet_tuning *tuning, int32_t max_bodies);
void jolt_puppet_world_destroy(jolt_puppet_world *w);
/// 足した順の番号、失敗なら −1。
int32_t jolt_puppet_world_add_body(jolt_puppet_world *w, const jolt_puppet_body_desc *d);
/// 両側の剛体は互いに当たらなくなる。失敗なら −1。
int32_t jolt_puppet_world_add_joint(jolt_puppet_world *w, const jolt_puppet_joint_desc *d);
void jolt_puppet_world_finish(jolt_puppet_world *w);
/// 全部の剛体を作ったときの位置へ戻し、速さを 0 にする。
void jolt_puppet_world_reset(jolt_puppet_world *w);
/// キネマティックをすぐ置いた位置へ移し、全部の速さを 0 にする。
void jolt_puppet_world_settle(jolt_puppet_world *w);
/// キネマティックは置いた位置へ `dt` かけて動く。
void jolt_puppet_world_step(jolt_puppet_world *w, float dt, int32_t steps);
/// 動く剛体はすぐ移し、キネマティックは次の `step` で動かす。
void jolt_puppet_world_set_transform(jolt_puppet_world *w, int32_t i, const float position[3], const float rotation[4]);
void jolt_puppet_world_get_transform(const jolt_puppet_world *w, int32_t i, float position[3], float rotation[4]);
void jolt_puppet_world_set_gravity(jolt_puppet_world *w, const float g[3]);
/// 半分の大きさ（MMD 単位）。
void jolt_puppet_world_set_box(jolt_puppet_world *w, int32_t i, const float half[3]);

#ifdef __cplusplus
}
#endif

#endif
