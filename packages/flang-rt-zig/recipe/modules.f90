! Exercises the parts of flang most likely to be broken by a mis-built runtime
! or a bad module-file path: modules (.mod generation and consumption),
! allocatables, derived types, and array intrinsics.
module geometry
  implicit none
  private
  public :: point, distance, centroid

  type :: point
    real(kind=8) :: x = 0.0d0
    real(kind=8) :: y = 0.0d0
  end type point

contains

  pure function distance(a, b) result(d)
    type(point), intent(in) :: a, b
    real(kind=8) :: d
    d = sqrt((a%x - b%x)**2 + (a%y - b%y)**2)
  end function distance

  pure function centroid(pts) result(c)
    type(point), intent(in) :: pts(:)
    type(point) :: c
    c%x = sum(pts%x) / real(size(pts), kind=8)
    c%y = sum(pts%y) / real(size(pts), kind=8)
  end function centroid

end module geometry


program modules_test
  use geometry
  implicit none

  type(point), allocatable :: pts(:)
  type(point) :: c
  real(kind=8) :: d
  integer :: i

  allocate (pts(4))
  pts(1) = point(0.0d0, 0.0d0)
  pts(2) = point(4.0d0, 0.0d0)
  pts(3) = point(4.0d0, 4.0d0)
  pts(4) = point(0.0d0, 4.0d0)

  d = distance(pts(1), pts(3))
  c = centroid(pts)

  print *, 'diagonal  =', d
  print *, 'centroid  =', c%x, c%y

  if (abs(d - sqrt(32.0d0)) > 1.0d-9) stop 1
  if (abs(c%x - 2.0d0) > 1.0d-9) stop 2
  if (abs(c%y - 2.0d0) > 1.0d-9) stop 3

  do i = 1, size(pts)
    if (pts(i)%x < -1.0d0) stop 4
  end do

  deallocate (pts)
  print *, 'modules: OK'
end program modules_test
