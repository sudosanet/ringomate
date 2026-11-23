#include <Jolt/Jolt.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/JobSystemSingleThreaded.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Collision/BroadPhase/BroadPhaseLayerInterfaceMask.h>
#include <Jolt/Physics/Collision/BroadPhase/ObjectVsBroadPhaseLayerFilterMask.h>
#include <Jolt/Physics/Collision/GroupFilterTable.h>
#include <Jolt/Physics/Collision/ObjectLayerPairFilterMask.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Constraints/SixDOFConstraint.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/RegisterTypes.h>

#include <cmath>
#include <memory>
#include <mutex>
#include <vector>

#include "jolt_puppet_api.h"

using namespace JPH;

void jolt_init_once() {
    static std::once_flag flag;
    std::call_once(flag, [] {
        RegisterDefaultAllocator();
        Factory::sInstance = new Factory();
        RegisterTypes();
    });
}

namespace {

constexpr float kScale = 0.08f;

float or_default(float v, float d) { return v > 0 ? v : d; }

jolt_puppet_tuning with_defaults(const jolt_puppet_tuning *in) {
    jolt_puppet_tuning t = in ? *in : jolt_puppet_tuning{};
    t.spring_frequency_scale = or_default(t.spring_frequency_scale, 0.25f);
    t.spring_frequency_min = or_default(t.spring_frequency_min, 0.3f);
    t.spring_frequency_max = or_default(t.spring_frequency_max, 6.0f);
    t.spring_damping = or_default(t.spring_damping, 0.4f);
    t.max_angular_velocity = or_default(t.max_angular_velocity, 12.0f);
    t.max_linear_velocity = or_default(t.max_linear_velocity, 400.0f);
    t.inertia_multiplier = or_default(t.inertia_multiplier, 3.0f);
    t.penetration_slop = or_default(t.penetration_slop, 0.002f);
    t.speculative_distance = or_default(t.speculative_distance, 0.005f);
    if (t.velocity_steps <= 0) t.velocity_steps = 10;
    if (t.position_steps <= 0) t.position_steps = 2;
    return t;
}

Vec3 v3(const float a[3], float s = 1) { return Vec3(a[0] * s, a[1] * s, a[2] * s); }
Quat q4(const float a[4]) { return Quat(a[0], a[1], a[2], a[3]).Normalized(); }

// PMX の減衰（1 秒で速さに (1 − d) を掛ける）→ Jolt の dv/dt = −c·v
float damping(float d) { return -std::log(1.0f - std::fmin(std::fmax(d, 0.0f), 0.99f)); }

}

struct jolt_puppet_world {
    jolt_puppet_tuning t;
    BroadPhaseLayerInterfaceMask layers{1};
    ObjectVsBroadPhaseLayerFilterMask objectVsLayer{layers};
    ObjectLayerPairFilterMask pairs;
    PhysicsSystem system;
    TempAllocatorImpl temp{16 * 1024 * 1024};
    std::unique_ptr<JobSystem> jobs;
    Ref<GroupFilterTable> groups;
    struct Item {
        BodyID id;
        RVec3 position;
        Quat rotation;
        bool kinematic;
        bool moved = false;
        RVec3 target;
        Quat targetRotation;
    };
    std::vector<Item> items;
    int32_t maxBodies;

    jolt_puppet_world(const jolt_puppet_tuning &tuning, int32_t max) : t(tuning), maxBodies(max) {
        layers.ConfigureLayer(BroadPhaseLayer(0), 0xffff, 0);
        system.Init(max + 16, 0, 16384, 8192, layers, objectVsLayer, pairs);
        PhysicsSettings ps;
        ps.mNumVelocitySteps = t.velocity_steps;
        ps.mNumPositionSteps = t.position_steps;
        ps.mPenetrationSlop = t.penetration_slop;
        ps.mSpeculativeContactDistance = t.speculative_distance;
        ps.mAllowSleeping = false;
        system.SetPhysicsSettings(ps);
        groups = new GroupFilterTable(uint(max));
        if (t.threads > 0)
            jobs = std::make_unique<JobSystemThreadPool>(cMaxPhysicsJobs, cMaxPhysicsBarriers, t.threads);
        else
            jobs = std::make_unique<JobSystemSingleThreaded>(cMaxPhysicsJobs);
    }

    BodyInterface &bodies() { return system.GetBodyInterfaceNoLock(); }
};

extern "C" {

jolt_puppet_world *jolt_puppet_world_create(const jolt_puppet_tuning *tuning, int32_t max_bodies) {
    if (max_bodies <= 0) return nullptr;
    jolt_init_once();
    return new jolt_puppet_world(with_defaults(tuning), max_bodies);
}

void jolt_puppet_world_destroy(jolt_puppet_world *w) {
    if (!w) return;
    for (auto &it : w->items) {
        w->bodies().RemoveBody(it.id);
        w->bodies().DestroyBody(it.id);
    }
    delete w;
}

int32_t jolt_puppet_world_add_body(jolt_puppet_world *w, const jolt_puppet_body_desc *d) {
    if (!w || !d || int32_t(w->items.size()) >= w->maxBodies) return -1;
    const float s0 = std::fmax(d->size[0], 1e-4f) * kScale, s1 = std::fmax(d->size[1], 1e-4f) * kScale,
                s2 = std::fmax(d->size[2], 1e-4f) * kScale;
    RefConst<Shape> shape;
    switch (d->shape) {
    case JOLT_PUPPET_SPHERE: shape = new SphereShape(s0); break;
    case JOLT_PUPPET_BOX: shape = new BoxShape(Vec3(s0, s1, s2), 0.25f * std::fmin(s0, std::fmin(s1, s2))); break;
    case JOLT_PUPPET_CAPSULE:
        if (d->size[1] * 0.5f * kScale > 1e-5f) shape = new CapsuleShape(d->size[1] * 0.5f * kScale, s0);
        else shape = new SphereShape(s0);
        break;
    default: return -1;
    }
    const bool kinematic = !(d->mass > 0);
    const RVec3 pos = RVec3(v3(d->position, kScale));
    const Quat rot = q4(d->rotation);
    const uint16 group = d->group ? d->group : 1;
    BodyCreationSettings bs(shape, pos, rot, kinematic ? EMotionType::Kinematic : EMotionType::Dynamic,
                            ObjectLayerPairFilterMask::sGetObjectLayer(group, d->mask));
    const int32_t index = int32_t(w->items.size());
    bs.mCollisionGroup = CollisionGroup(w->groups, 0, CollisionGroup::SubGroupID(index));
    bs.mFriction = d->friction;
    bs.mRestitution = d->restitution;
    bs.mAllowSleeping = false;
    if (!kinematic) {
        bs.mOverrideMassProperties = EOverrideMassProperties::CalculateInertia;
        bs.mMassPropertiesOverride.mMass = d->mass;
        bs.mInertiaMultiplier = w->t.inertia_multiplier;
        bs.mLinearDamping = damping(d->linear_damping);
        bs.mAngularDamping = damping(d->angular_damping);
        bs.mMaxAngularVelocity = w->t.max_angular_velocity;
        bs.mMaxLinearVelocity = w->t.max_linear_velocity * kScale;
        if (d->ccd) bs.mMotionQuality = EMotionQuality::LinearCast;
    }
    const BodyID id = w->bodies().CreateAndAddBody(bs, EActivation::Activate);
    if (id.IsInvalid()) return -1;
    w->items.push_back({id, pos, rot, kinematic, false, pos, rot});
    return index;
}

int32_t jolt_puppet_world_add_joint(jolt_puppet_world *w, const jolt_puppet_joint_desc *d) {
    if (!w || !d) return -1;
    const int32_t n = int32_t(w->items.size());
    if (d->body_a < 0 || d->body_b < 0 || d->body_a >= n || d->body_b >= n || d->body_a == d->body_b) return -1;
    const Quat q = q4(d->rotation);
    const Vec3 axes[3] = {q * Vec3::sAxisX(), q * Vec3::sAxisY(), q * Vec3::sAxisZ()};
    // ツイストの軸は鎖の向きにいちばん近い軸。巡回で並べ替えて右手系のまま
    const Vec3 chain = Vec3(w->items[size_t(d->body_b)].position - w->items[size_t(d->body_a)].position);
    int k = 0;
    float best = -1;
    for (int i = 0; i < 3; ++i) {
        const float c = std::fabs(chain.Dot(axes[i]));
        if (c > best) best = c, k = i;
    }
    const int perm[3] = {k, (k + 1) % 3, (k + 2) % 3};

    SixDOFConstraintSettings s;
    s.mSpace = EConstraintSpace::WorldSpace;
    s.mPosition1 = s.mPosition2 = RVec3(v3(d->position, kScale));
    s.mAxisX1 = s.mAxisX2 = axes[perm[0]];
    s.mAxisY1 = s.mAxisY2 = axes[perm[1]];
    s.mSwingType = ESwingType::Pyramid;
    bool springs[6] = {};
    for (int i = 0; i < 3; ++i) {
        const int o = perm[i];
        const auto ta = SixDOFConstraintSettings::EAxis(SixDOFConstraintSettings::TranslationX + i);
        const float tl = d->translation_lower[o] * kScale, tu = d->translation_upper[o] * kScale;
        if (tl > tu) s.MakeFreeAxis(ta);
        else if (tl == tu) s.MakeFixedAxis(ta);
        else s.SetLimitedAxis(ta, tl, tu);
        // PMX は下限 > 上限が自由、Jolt は固定として扱う
        const auto ra = SixDOFConstraintSettings::EAxis(SixDOFConstraintSettings::RotationX + i);
        const float rl = d->rotation_lower[o], ru = d->rotation_upper[o];
        if (rl > ru || d->side) s.SetLimitedAxis(ra, -JPH_PI, JPH_PI);
        else if (rl == ru) s.MakeFixedAxis(ra);
        else s.SetLimitedAxis(ra, std::fmax(rl, -JPH_PI), std::fmin(ru, JPH_PI));
        const float kr[2] = {d->spring_translation[o], d->spring_rotation[o]};
        const SixDOFConstraintSettings::EAxis ax[2] = {ta, ra};
        for (int j = 0; j < 2; ++j) {
            if (!(kr[j] > 0) || s.IsFixedAxis(ax[j])) continue;
            const float f = std::fmin(std::fmax(w->t.spring_frequency_scale * std::sqrt(kr[j]), w->t.spring_frequency_min),
                                      w->t.spring_frequency_max);
            s.mMotorSettings[ax[j]].mSpringSettings = SpringSettings(ESpringMode::FrequencyAndDamping, f, w->t.spring_damping);
            springs[ax[j]] = true;
        }
    }
    Body *a = w->system.GetBodyLockInterfaceNoLock().TryGetBody(w->items[size_t(d->body_a)].id);
    Body *b = w->system.GetBodyLockInterfaceNoLock().TryGetBody(w->items[size_t(d->body_b)].id);
    if (!a || !b) return -1;
    auto *c = static_cast<SixDOFConstraint *>(s.Create(*a, *b));
    c->SetTargetOrientationCS(Quat::sIdentity());
    c->SetTargetPositionCS(Vec3::sZero());
    for (int i = 0; i < 6; ++i)
        if (springs[i]) c->SetMotorState(SixDOFConstraintSettings::EAxis(i), EMotorState::Position);
    w->system.AddConstraint(c);
    w->groups->DisableCollision(CollisionGroup::SubGroupID(d->body_a), CollisionGroup::SubGroupID(d->body_b));
    return int32_t(w->system.GetConstraints().size()) - 1;
}

void jolt_puppet_world_finish(jolt_puppet_world *w) {
    if (w) w->system.OptimizeBroadPhase();
}

void jolt_puppet_world_reset(jolt_puppet_world *w) {
    if (!w) return;
    for (auto &it : w->items) {
        w->bodies().SetPositionAndRotation(it.id, it.position, it.rotation, EActivation::Activate);
        w->bodies().SetLinearAndAngularVelocity(it.id, Vec3::sZero(), Vec3::sZero());
        it.moved = false;
    }
}

void jolt_puppet_world_settle(jolt_puppet_world *w) {
    if (!w) return;
    for (auto &it : w->items) {
        if (it.kinematic && it.moved)
            w->bodies().SetPositionAndRotation(it.id, it.target, it.targetRotation, EActivation::Activate);
        w->bodies().SetLinearAndAngularVelocity(it.id, Vec3::sZero(), Vec3::sZero());
        it.moved = false;
    }
}

void jolt_puppet_world_step(jolt_puppet_world *w, float dt, int32_t steps) {
    if (!w || !(dt > 0) || steps <= 0) return;
    for (auto &it : w->items) {
        if (!it.kinematic) continue;
        const bool moved = it.moved;
        it.moved = false;
        if (!moved) {
            w->bodies().SetLinearAndAngularVelocity(it.id, Vec3::sZero(), Vec3::sZero());
            continue;
        }
        // 大きな飛び（隠していた小道具・床を出す）は置き直す。MoveKinematic だと揺れものを弾く
        if (Vec3(it.target - w->bodies().GetPosition(it.id)).Length() > 1.0f) {
            w->bodies().SetPositionAndRotation(it.id, it.target, it.targetRotation, EActivation::Activate);
            w->bodies().SetLinearAndAngularVelocity(it.id, Vec3::sZero(), Vec3::sZero());
        } else {
            w->bodies().MoveKinematic(it.id, it.target, it.targetRotation, dt);
        }
    }
    w->system.Update(dt, steps, &w->temp, w->jobs.get());
}

void jolt_puppet_world_set_transform(jolt_puppet_world *w, int32_t i, const float position[3], const float rotation[4]) {
    if (!w || i < 0 || i >= int32_t(w->items.size())) return;
    auto &it = w->items[size_t(i)];
    const RVec3 p = RVec3(v3(position, kScale));
    const Quat q = q4(rotation);
    if (it.kinematic) {
        it.target = p;
        it.targetRotation = q;
        it.moved = true;
    } else {
        w->bodies().SetPositionAndRotation(it.id, p, q, EActivation::Activate);
        w->bodies().SetLinearAndAngularVelocity(it.id, Vec3::sZero(), Vec3::sZero());
    }
}

void jolt_puppet_world_get_transform(const jolt_puppet_world *w, int32_t i, float position[3], float rotation[4]) {
    if (!w || i < 0 || i >= int32_t(w->items.size())) return;
    RVec3 p;
    Quat q;
    const_cast<jolt_puppet_world *>(w)->bodies().GetPositionAndRotation(w->items[size_t(i)].id, p, q);
    position[0] = float(p.GetX()) / kScale;
    position[1] = float(p.GetY()) / kScale;
    position[2] = float(p.GetZ()) / kScale;
    rotation[0] = q.GetX();
    rotation[1] = q.GetY();
    rotation[2] = q.GetZ();
    rotation[3] = q.GetW();
}

void jolt_puppet_world_set_gravity(jolt_puppet_world *w, const float g[3]) {
    if (!w || !std::isfinite(g[0]) || !std::isfinite(g[1]) || !std::isfinite(g[2])) return;
    w->system.SetGravity(v3(g, kScale));
}

void jolt_puppet_world_set_box(jolt_puppet_world *w, int32_t i, const float half[3]) {
    if (!w || i < 0 || i >= int32_t(w->items.size())) return;
    const Vec3 h = Vec3::sMax(v3(half, kScale), Vec3::sReplicate(1e-4f));
    w->bodies().SetShape(w->items[size_t(i)].id, new BoxShape(h, 0.25f * h.ReduceMin()), false, EActivation::DontActivate);
}

}
