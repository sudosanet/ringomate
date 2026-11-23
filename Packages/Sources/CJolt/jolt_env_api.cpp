#include <Jolt/Jolt.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/JobSystemSingleThreaded.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Collision/BroadPhase/BroadPhaseLayerInterfaceMask.h>
#include <Jolt/Physics/Collision/BroadPhase/ObjectVsBroadPhaseLayerFilterMask.h>
#include <Jolt/Physics/Collision/ContactListener.h>
#include <Jolt/Physics/Collision/ObjectLayerPairFilterMask.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/RegisterTypes.h>

#include <algorithm>
#include <cmath>
#include <mutex>
#include <vector>

#include "jolt_env_api.h"

using namespace JPH;

void jolt_init_once();

namespace {

constexpr float kScale = 0.08f;
constexpr uint64 kCharacter = 0, kStage = 1, kPlatform = 100;  // mUserData: 足場は kPlatform + 番号
constexpr float kThick = 0.5f * kScale;
const RVec3 kAway(0, -1.0e3, 0);

}

struct jolt_env final : public ContactListener {
    BroadPhaseLayerInterfaceMask layers{1};
    ObjectVsBroadPhaseLayerFilterMask objectVsLayer{layers};
    ObjectLayerPairFilterMask pairs;
    PhysicsSystem system;
    TempAllocatorImpl temp{1024 * 1024};
    JobSystemSingleThreaded jobs{cMaxPhysicsJobs};
    BodyID character, floor, left, right;
    std::vector<BodyID> platforms;
    std::vector<Vec3> spans;
    int32_t ignore = -1;
    int32_t support = -2;
    float radius, half;
    float width = 0, ground = 0;
    float startFoot = 0;
    bool walking = false;

    BodyInterface &bodies() { return system.GetBodyInterfaceNoLock(); }

    RVec3 center(float x, float y) const { return RVec3(x * kScale, y * kScale + half + radius, 0); }

    // 足場は上から来たときだけ当たる
    ValidateResult OnContactValidate(const Body &a, const Body &b, RVec3Arg, const CollideShapeResult &) override {
        const Body &c = a.GetUserData() == kCharacter ? a : b, &o = &c == &a ? b : a;
        if (o.GetUserData() < kPlatform) return ValidateResult::AcceptAllContactsForThisBodyPair;
        const int32_t i = int32_t(o.GetUserData() - kPlatform);
        if (i == ignore || size_t(i) >= spans.size()) return ValidateResult::RejectAllContactsForThisBodyPair;
        // 速く落ちると刻みの途中で足元が上端の下にあるので、フレームの初めの足元も見る
        const float foot = std::fmax(float(c.GetPosition().GetY()) - half - radius, startFoot);
        if (foot < spans[size_t(i)].GetZ() - 0.02f || c.GetLinearVelocity().GetY() > 0.05f)
            return ValidateResult::RejectContact;
        return ValidateResult::AcceptContact;
    }

    void OnContactAdded(const Body &a, const Body &b, const ContactManifold &m, ContactSettings &s) override { touch(a, b, m, s); }
    void OnContactPersisted(const Body &a, const Body &b, const ContactManifold &m, ContactSettings &s) override { touch(a, b, m, s); }

    void touch(const Body &a, const Body &b, const ContactManifold &m, ContactSettings &s) {
        if (walking) s.mCombinedFriction = 0;
        const bool first = a.GetUserData() == kCharacter;
        const Body &o = first ? b : a;
        const float up = first ? -m.mWorldSpaceNormal.GetY() : m.mWorldSpaceNormal.GetY();
        if (up < 0.5f || o.GetUserData() < kStage) return;
        if (o.GetID() == floor) support = -1;
        else if (o.GetUserData() >= kPlatform) support = int32_t(o.GetUserData() - kPlatform);
    }

    BodyID box(Vec3 halfSize, RVec3 at, EMotionType type, uint64 tag, float friction, float restitution) {
        BodyCreationSettings s(new BoxShape(halfSize, 0.0f), at, Quat::sIdentity(), type,
                               ObjectLayerPairFilterMask::sGetObjectLayer(2, 1));
        s.mUserData = tag;
        s.mFriction = friction;
        s.mRestitution = restitution;
        return bodies().CreateAndAddBody(s, EActivation::DontActivate);
    }
};

extern "C" {

jolt_env *jolt_env_create(float radius, float height, float gravity, float friction, float restitution, float damping) {
    jolt_init_once();
    auto *e = new jolt_env();
    e->layers.ConfigureLayer(BroadPhaseLayer(0), 0xffff, 0);
    e->system.Init(256, 0, 1024, 1024, e->layers, e->objectVsLayer, e->pairs);
    PhysicsSettings ps;
    ps.mMinVelocityForRestitution = 1.0f * kScale;
    ps.mAllowSleeping = false;
    e->system.SetPhysicsSettings(ps);
    e->system.SetContactListener(e);
    e->system.SetGravity(Vec3(0, gravity * kScale, 0));
    e->radius = std::fmax(radius, 0.05f) * kScale;
    e->half = std::fmax(height * kScale * 0.5f - e->radius, 0.01f);
    BodyCreationSettings s(new CapsuleShape(e->half, e->radius), e->center(0, 0), Quat::sIdentity(), EMotionType::Dynamic,
                           ObjectLayerPairFilterMask::sGetObjectLayer(1, 2));
    s.mUserData = kCharacter;
    s.mAllowedDOFs = EAllowedDOFs::TranslationX | EAllowedDOFs::TranslationY;
    s.mOverrideMassProperties = EOverrideMassProperties::CalculateInertia;
    s.mMassPropertiesOverride.mMass = 1;
    s.mFriction = friction;
    s.mRestitution = restitution;
    s.mLinearDamping = damping;
    s.mAllowSleeping = false;
    s.mMotionQuality = EMotionQuality::LinearCast;
    e->character = e->bodies().CreateAndAddBody(s, EActivation::Activate);
    const Vec3 big(1.0e3f, 1.0e3f, 1.0f);
    e->floor = e->box(big, kAway, EMotionType::Static, kStage, friction, 0);
    e->left = e->box(big, kAway, EMotionType::Static, kStage, 0, restitution);
    e->right = e->box(big, kAway, EMotionType::Static, kStage, 0, restitution);
    return e;
}

void jolt_env_destroy(jolt_env *e) {
    if (!e) return;
    for (BodyID id : {e->character, e->floor, e->left, e->right}) {
        e->bodies().RemoveBody(id);
        e->bodies().DestroyBody(id);
    }
    for (BodyID id : e->platforms) {
        e->bodies().RemoveBody(id);
        e->bodies().DestroyBody(id);
    }
    delete e;
}

void jolt_env_set_stage(jolt_env *e, float width, float ground) {
    if (!e) return;
    e->width = width;
    e->ground = ground;
    const float w = width * kScale, g = ground * kScale, b = 1.0e3f;
    e->bodies().SetPosition(e->floor, RVec3(w / 2, g - b, 0), EActivation::DontActivate);
    e->bodies().SetPosition(e->left, RVec3(-b, g + b, 0), EActivation::DontActivate);
    e->bodies().SetPosition(e->right, RVec3(w + b, g + b, 0), EActivation::DontActivate);
}

void jolt_env_set_platforms(jolt_env *e, const float *surfaces, int32_t count, int32_t ignore) {
    if (!e) return;
    if (ignore != e->ignore) {
        for (int32_t i : {ignore, e->ignore})
            if (i >= 0 && size_t(i) < e->platforms.size()) e->bodies().InvalidateContactCache(e->platforms[size_t(i)]);
    }
    e->ignore = ignore;
    count = std::max(count, 0);
    while (e->platforms.size() < size_t(count)) {
        const uint64 tag = kPlatform + e->platforms.size();
        e->platforms.push_back(e->box(Vec3(1, kThick, 1), kAway, EMotionType::Kinematic, tag, 0.4f, 0));
        e->spans.push_back(Vec3::sZero());
    }
    for (size_t i = 0; i < e->platforms.size(); ++i) {
        if (int32_t(i) >= count) {
            e->bodies().SetPosition(e->platforms[i], kAway, EActivation::DontActivate);
            e->spans[i] = Vec3(0, 0, -1.0e3f);
            continue;
        }
        const Vec3 s = Vec3(surfaces[3 * i], surfaces[3 * i + 1], surfaces[3 * i + 2]) * kScale;
        const float halfWidth = std::fmax((s.GetY() - s.GetX()) / 2, 0.01f);
        if (std::fabs(halfWidth - (e->spans[i].GetY() - e->spans[i].GetX()) / 2) > 1e-4f)
            e->bodies().SetShape(e->platforms[i], new BoxShape(Vec3(halfWidth, kThick, 1), 0.0f), false, EActivation::DontActivate);
        e->spans[i] = s;
        e->bodies().SetPosition(e->platforms[i], RVec3((s.GetX() + s.GetY()) / 2, s.GetZ() - kThick, 0), EActivation::DontActivate);
    }
}

void jolt_env_place(jolt_env *e, float x, float y, float vx, float vy) {
    if (!e) return;
    e->bodies().SetPosition(e->character, e->center(x, y), EActivation::Activate);
    e->bodies().SetLinearVelocity(e->character, Vec3(vx, vy, 0) * kScale);
}

void jolt_env_step(jolt_env *e, float dt, int32_t steps, float walk) {
    if (!e || !(dt > 0) || steps <= 0) return;
    e->walking = std::isfinite(walk) && walk != 0 && e->support != -2;
    if (std::isfinite(walk) && e->support != -2) {
        const Vec3 v = e->bodies().GetLinearVelocity(e->character);
        e->bodies().SetLinearVelocity(e->character, Vec3(walk * kScale, v.GetY(), 0));
    }
    e->support = -2;
    e->startFoot = float(e->bodies().GetPosition(e->character).GetY()) - e->half - e->radius;
    e->system.Update(dt, steps, &e->temp, &e->jobs);
}

void jolt_env_get(const jolt_env *e, float pos[2], float vel[2], int32_t *support) {
    if (!e) return;
    auto &b = const_cast<jolt_env *>(e)->bodies();
    const RVec3 p = b.GetPosition(e->character);
    const Vec3 v = b.GetLinearVelocity(e->character);
    pos[0] = float(p.GetX()) / kScale;
    pos[1] = (float(p.GetY()) - e->half - e->radius) / kScale;
    vel[0] = v.GetX() / kScale;
    vel[1] = v.GetY() / kScale;
    *support = e->support;
}

}
