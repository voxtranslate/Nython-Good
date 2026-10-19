# bm_raytrace - a small ray tracer in the style of pyperformance's
# bm_raytrace: a Vector class whose methods make new vectors, spheres and
# planes, Lambert and specular shading with shadows and reflection. Float
# arithmetic, attribute reads, method calls, isinstance, polymorphic
# intersect() calls. Runs under python3 too.
import math
import time

EPSILON = 0.00001


class Vector(object):

    def __init__(self, initx, inity, initz):
        self.x = initx
        self.y = inity
        self.z = initz

    def dot(self, other):
        return (self.x * other.x) + (self.y * other.y) + (self.z * other.z)

    def magnitude(self):
        return math.sqrt(self.dot(self))

    def add(self, other):
        return Vector(self.x + other.x, self.y + other.y, self.z + other.z)

    def sub(self, other):
        return Vector(self.x - other.x, self.y - other.y, self.z - other.z)

    def scale(self, factor):
        return Vector(factor * self.x, factor * self.y, factor * self.z)

    def cross(self, other):
        return Vector(self.y * other.z - self.z * other.y,
                      self.z * other.x - self.x * other.z,
                      self.x * other.y - self.y * other.x)

    def normalized(self):
        return self.scale(1.0 / self.magnitude())

    def negated(self):
        return self.scale(-1)

    def reflectThrough(self, normal):
        d = normal.scale(self.dot(normal))
        return self.sub(d.scale(2))


Vector.ZERO = Vector(0, 0, 0)
Vector.RIGHT = Vector(1, 0, 0)
Vector.UP = Vector(0, 1, 0)
Vector.OUT = Vector(0, 0, 1)


class Point(Vector):
    pass


class Ray(object):

    def __init__(self, point, vector):
        self.point = point
        self.vector = vector.normalized()

    def pointAtTime(self, t):
        return self.point.add(self.vector.scale(t))


class Sphere(object):

    def __init__(self, centre, radius):
        self.centre = centre
        self.radius = radius

    def intersectionTime(self, ray):
        cp = self.centre.sub(ray.point)
        v = cp.dot(ray.vector)
        discriminant = (self.radius * self.radius) - (cp.dot(cp) - v * v)
        if discriminant < 0:
            return None
        else:
            return v - math.sqrt(discriminant)

    def normalAt(self, p):
        return (p.sub(self.centre)).normalized()


class Halfspace(object):

    def __init__(self, point, normal):
        self.point = point
        self.normal = normal.normalized()

    def intersectionTime(self, ray):
        v = ray.vector.dot(self.normal)
        if v:
            return 1 / -v
        else:
            return None

    def normalAt(self, p):
        return self.normal


class Colour(object):

    def __init__(self, r, g, b):
        self.r = r
        self.g = g
        self.b = b

    def add(self, other):
        return Colour(self.r + other.r, self.g + other.g, self.b + other.b)

    def scale(self, f):
        return Colour(self.r * f, self.g * f, self.b * f)

    def mul(self, other):
        return Colour(self.r * other.r, self.g * other.g, self.b * other.b)


class Scene(object):

    def __init__(self):
        self.objects = []
        self.lightPoints = []
        self.position = Point(0, 1.8, 10)
        self.lookingAt = Point(0, 0, 0)
        self.fieldOfView = 45
        self.recursionDepth = 0

    def addObject(self, obj, colour, reflect):
        self.objects.append((obj, colour, reflect))

    def addLight(self, p):
        self.lightPoints.append(p)

    def render(self, width, height):
        fovRadians = math.pi * (self.fieldOfView / 2.0) / 180.0
        halfWidth = math.tan(fovRadians)
        halfHeight = 0.75 * halfWidth
        pixelWidth = halfWidth * 2.0 / (width - 1)
        pixelHeight = halfHeight * 2.0 / (height - 1)

        eye = Ray(self.position, self.lookingAt.sub(self.position))
        vpRight = eye.vector.cross(Vector.UP).normalized()
        vpUp = vpRight.cross(eye.vector).normalized()

        total = 0.0
        for y in range(height):
            for x in range(width):
                xcomp = vpRight.scale(x * pixelWidth - halfWidth)
                ycomp = vpUp.scale(y * pixelHeight - halfHeight)
                ray = Ray(eye.point, eye.vector.add(xcomp).add(ycomp))
                colour = self.rayColour(ray)
                total += colour.r + colour.g + colour.b
        return total

    def rayColour(self, ray):
        if self.recursionDepth > 3:
            return Colour(0, 0, 0)
        try:
            self.recursionDepth = self.recursionDepth + 1
            intersections = []
            for (o, c, r) in self.objects:
                t = o.intersectionTime(ray)
                if t is not None and t > EPSILON:
                    intersections.append((o, t, c, r))
            if not intersections:
                return Colour(0, 0, 0)
            best = intersections[0]
            for i in intersections:
                if i[1] < best[1]:
                    best = i
            (o, t, c, r) = best
            p = ray.pointAtTime(t)
            return self.lightColour(o, p, c, r, ray)
        finally:
            self.recursionDepth = self.recursionDepth - 1

    def visible(self, p, light):
        ray = Ray(p, light.sub(p))
        for (o, c, r) in self.objects:
            t = o.intersectionTime(ray)
            if t is not None and t > EPSILON:
                return False
        return True

    def lightColour(self, obj, p, colour, reflect, ray):
        normal = obj.normalAt(p)
        lambert = 0.0
        for light in self.lightPoints:
            if self.visible(p, light):
                contribution = light.sub(p).normalized().dot(normal)
                if contribution > 0:
                    lambert += contribution
        lambert = min(1.0, lambert)
        result = colour.scale(lambert * 0.7 + 0.2)
        if reflect > 0:
            rray = Ray(p, ray.vector.reflectThrough(normal))
            result = result.add(self.rayColour(rray).scale(reflect))
        return result


def main():
    t0 = time.perf_counter()
    s = Scene()
    s.addLight(Point(30, 30, 10))
    s.addLight(Point(-10, 100, 30))
    s.addObject(Sphere(Point(1, 3, -10), 2), Colour(1, 1, 0), 0.5)
    for y in range(6):
        s.addObject(Sphere(Point(-3 - y * 0.4, 2.3, -5), 0.4), Colour(y / 6.0, 1 - y / 6.0, 0.5), 0.2)
    s.addObject(Halfspace(Point(0, 0, 0), Vector.UP), Colour(0.3, 0.6, 0.3), 0.3)
    total = s.render(40, 30)
    t1 = time.perf_counter()
    print("result", "%.6f" % total)
    print("bench_time", t1 - t0)

main()
