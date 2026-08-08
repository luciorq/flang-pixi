! Minimal frontend smoke test for the stage-2 package test.
! Compiled with `flang -S -emit-llvm` only — stage 2 has no runtime to link.
program hello
  implicit none
  integer :: i
  real(kind=8) :: acc

  acc = 0.0d0
  do i = 1, 10
    acc = acc + real(i, kind=8) ** 2
  end do

  print *, 'sum of squares 1..10 =', acc
end program hello
