program omp_directives
  implicit none
  integer :: i, n, s
  integer, dimension(1000) :: a
  n = 0
  !$omp parallel do reduction(+:n)
  do i = 1, 1000
     a(i) = i
     n = n + 1
  end do
  !$omp end parallel do
  s = sum(a)
  print '(a,i0,a,i0)', 'iterations=', n, ' sum=', s
  if (n /= 1000 .or. s /= 500500) stop 1
end program
