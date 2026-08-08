! Baseline: does the compiler produce a binary that runs at all?
! Exercises I/O, which pulls in a large slice of the Fortran runtime.
program hello
  implicit none
  integer :: i
  real(kind=8) :: acc

  acc = 0.0d0
  do i = 1, 10
    acc = acc + real(i, kind=8) ** 2
  end do

  print *, 'sum of squares 1..10 =', acc
  if (abs(acc - 385.0d0) > 1.0d-9) then
    write (*, *) 'FAIL: expected 385'
    stop 1
  end if
  print *, 'hello: OK'
end program hello
