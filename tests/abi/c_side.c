/*
 * Mixed-toolchain ABI probe — the C half, compiled with `zig cc`.
 *
 * Mirrors the way R calls Fortran: lowercase name, single trailing underscore,
 * everything by reference, hidden CHARACTER lengths appended as size_t.
 */
#include <stdio.h>
#include <stddef.h>
#include <math.h>
#include <complex.h>

double abi_scale(double x, double f);              /* bind(C) */
void   abisum_(const double *a, const int *n, double *s);
void   abicmul_(const double _Complex *a, const double _Complex *b,
                double _Complex *c);
void   abichr_(const char *s, int *n, size_t s_len); /* hidden length last */

static int failures = 0;

static void check(const char *what, int ok)
{
    printf("  %-28s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) failures++;
}

int main(void)
{
    /* 1. bind(C) scalars by value */
    check("bind(C) scalar by value", fabs(abi_scale(2.5, 4.0) - 10.0) < 1e-12);

    /* 2. F77 assumed-size array by reference — the .Fortran() convention */
    double a[5] = {1.0, 2.0, 3.0, 4.0, 5.0};
    int n = 5;
    double s = 0.0;
    abisum_(a, &n, &s);
    check("assumed-size array byref", fabs(s - 15.0) < 1e-12);

    /* 3. COMPLEX*16 — the historically fragile one */
    double _Complex x = 1.0 + 2.0 * I;
    double _Complex y = 3.0 - 1.0 * I;
    double _Complex z = 0.0;
    abicmul_(&x, &y, &z);
    /* (1+2i)(3-i) = 3 - i + 6i - 2i^2 = 5 + 5i */
    check("complex*16 argument",
          fabs(creal(z) - 5.0) < 1e-12 && fabs(cimag(z) - 5.0) < 1e-12);

    /* 4. CHARACTER with hidden length */
    const char *msg = "abcdefg";
    int len = -1;
    abichr_(msg, &len, (size_t) 7);
    check("hidden character length", len == 7);

    if (failures) {
        printf("\nABI PROBE FAILED (%d)\n", failures);
        printf("zig cc and flang disagree about calling conventions.\n");
        printf("Do NOT wire this compiler into r-zig-pixi.\n");
        return 1;
    }
    printf("\nABI probe passed: zig cc and flang agree.\n");
    return 0;
}
