! A parallel region that shares ten variables: flang outlines it into a
! function with more than six pointer arguments, which libomp's
! __kmp_invoke_microtask must pass on the stack. conda-forge's win-arm64
! libomp (MSVC build, C fallback) dropped every argument after the sixth and
! the region crashed or read garbage (docs/10 2026-11-11). Any platform whose
! libomp gets this wrong fails here.
program omp_many_args
  use omp_lib
  implicit none
  integer, parameter :: n = 100000
  real(8) :: a(n), b(n), c(n), d(n), e(n)
  real(8) :: s1, s2, s3, s4, s5
  integer :: i

  a = 1.0d0; b = 2.0d0; c = 3.0d0; d = 4.0d0; e = 5.0d0
  s1 = 0; s2 = 0; s3 = 0; s4 = 0; s5 = 0
  !$omp parallel shared(a, b, c, d, e) reduction(+:s1, s2, s3, s4, s5)
  !$omp do
  do i = 1, n
     s1 = s1 + a(i)
     s2 = s2 + b(i)
     s3 = s3 + c(i)
     s4 = s4 + d(i)
     s5 = s5 + e(i)
  end do
  !$omp end do
  !$omp end parallel
  print '(a,i0,5(1x,f0.1))', 'threads=', omp_get_max_threads(), s1, s2, s3, s4, s5
  if (s1 /= 1.0d0*n .or. s2 /= 2.0d0*n .or. s3 /= 3.0d0*n .or. &
      s4 /= 4.0d0*n .or. s5 /= 5.0d0*n) stop 1
end program
