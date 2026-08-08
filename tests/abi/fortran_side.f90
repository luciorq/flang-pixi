! Mixed-toolchain ABI probe — the Fortran half.
!
! Compiled with our flang; the C half is compiled with `zig cc`. If these two
! disagree about calling conventions, R's LAPACK/BLAS will return silently
! wrong numbers rather than crash — which is exactly the failure mode that bit
! r-zig-pixi with gfortran on arm64-darwin.
!
! Each routine probes a convention that has historically differed between
! Fortran compilers. Deliberately uses only the subset that actually crosses
! the R/C boundary: assumed-size arrays and scalars, never assumed-shape or
! allocatable dummies (whose descriptors are compiler-private and never cross).

! 1. Scalar double in, double out. The baseline.
function abi_scale(x, f) result(y) bind(C, name="abi_scale")
  use, intrinsic :: iso_c_binding, only: c_double
  real(c_double), value :: x, f
  real(c_double) :: y
  y = x * f
end function abi_scale

! 2. Classic F77 style: everything by reference, no bind(C).
!    This is how R's .Fortran() actually calls things — name mangled to
!    lowercase with a single trailing underscore.
subroutine abisum(a, n, s)
  implicit none
  integer :: n
  double precision :: a(*)
  double precision :: s
  integer :: i
  s = 0.0d0
  do i = 1, n
    s = s + a(i)
  end do
end subroutine abisum

! 3. COMPLEX*16 return value. The single most common ABI mismatch between
!    Fortran compilers on x86-64 and aarch64.
subroutine abicmul(a, b, c)
  implicit none
  complex*16 :: a, b, c
  c = a * b
end subroutine abicmul

! 4. CHARACTER argument with a hidden length. gfortran and flang both pass the
!    length as a trailing size_t; this asserts it.
subroutine abichr(s, n)
  implicit none
  character*(*) :: s
  integer :: n
  n = len(s)
end subroutine abichr
