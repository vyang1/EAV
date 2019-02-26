-- From_RI_WH
SET NOCOUNT ON
SET ANSI_WARNINGS OFF

declare @startDateKey as bigint
declare @endDateKey as bigint

set @startDateKey = (select DateKey from Warehouse.dbo.DateDim where DateValue = '20190101')
set @endDateKey = (select DateKey from Warehouse.dbo.DateDim where DateValue = '20190201')


IF OBJECT_ID('tempdb..#pos') IS NOT NULL DROP TABLE #pos
IF OBJECT_ID('tempdb..#prov') IS NOT NULL DROP TABLE #prov
IF OBJECT_ID('tempdb..#svcDep') IS NOT NULL DROP TABLE #svcDep
IF OBJECT_ID('tempdb..#apptPD') IS NOT NULL DROP TABLE #apptPD
IF OBJECT_ID('tempdb..#chargeInfo') IS NOT NULL DROP TABLE #chargeInfo
IF OBJECT_ID('tempdb..#chargeDetail') IS NOT NULL DROP TABLE #chargeDetail
IF OBJECT_ID('tempdb..#hars') IS NOT NULL DROP TABLE #hars
IF OBJECT_ID('tempdb..#preVF') IS NOT NULL DROP TABLE #preVF
IF OBJECT_ID('tempdb..#EF_exVF') IS NOT NULL DROP TABLE #EF_exVF


---- Appointment Statuses
select top 10000
 AppointmentProfileKey
,AppointmentStatus
,case when AppointmentStatus in ('Completed','Arrived') then 1 end as WH_EncounterCount
,case when AppointmentStatus in ('Completed','Arrived') then 1 -- 1 = visit
	when AppointmentStatus = 'Left without seen' then 2  -- 2 = left without seen
	when AppointmentStatus = 'No Show' then 3  -- 3 = No Show
	when AppointmentStatus in ('Scheduled','Confirmed') then 4 -- scheduled with or without confirmation
	else 5 end as WH_StatusGroupingNumber -- 5 = other
,case when AppointmentStatus = 'Completed' then '1 - Completed'
	when AppointmentStatus = 'Arrived' then '2 - Arrived'
	when AppointmentStatus = 'Scheduled' then '3 - Scheduled'
	when AppointmentStatus = 'No Show' then '4 - No Show'
	when AppointmentStatus = 'Left without seen' then '5 - Left without Seen'
	else AppointmentStatus
	end as WH_AppointmentStatusWithSort

into #apptPD	 

from 
Warehouse.dbo.AppointmentProfileDim

where
AppointmentStatus not in  ('Canceled','HH Incomplete')

create nonclustered index apd1 on #apptPD (AppointmentProfileKey) include (AppointmentStatus, WH_StatusGroupingNumber)

---- service departments
select top 10000
 DepartmentKey as ServiceDepartmentKey
,DepartmentEpicId as ServiceDepartmentId
,DepartmentName as ServiceDepartmentName
,DepartmentName + ' [' + cast(DepartmentEpicId as varchar(24)) + ']' as ServiceDepartment
,ServiceAreaEpicId
,LocationEpicId
,LocationName
,LocationName + ' [' + CAST(LocationEpicId as varchar(24)) + ']' as Location

into #svcDep

from
 Warehouse.dbo.DepartmentDim

where
 IdType = 'EpicDepartmentId'
 and ServiceAreaEpicId = '10'

union all

select top 10000
 DepartmentKey
,cast(DepartmentEpicId as varchar(24))
,DepartmentName
,DepartmentName
,ServiceAreaEpicId
,LocationEpicId
,LocationName
,LocationName

from
 Warehouse.dbo.DepartmentDim

where
 DepartmentKey < 1

 create clustered index d1 on #svcDep (ServiceDepartmentKey)


---- place of service
select top 10000
 PlaceOfServiceKey
,PlaceOfServiceEpicId
,Name as PlaceOfServiceName
,case when PlaceOfServiceKey > 0 then Name + ' [' + cast(PlaceOfServiceEpicId as varchar(24)) + ']' 
	else Name end as PlaceOfService
,Type as PlaceOfServiceType

into #pos

from
 Warehouse.dbo.PlaceOfServiceDim

where
PlaceOfServiceKey < 1
or IdType = 'EpicFacilityProfileId'

create clustered index pos1 on #pos (PlaceOfServiceKey)


---- Current Provider info
select top 10000
 ProviderKey
,DurableKey as ProviderDurableKey
,case when ProviderKey < 0 then Name
	when ProviderEpicId in ('','*Deleted') then Name
	else Name + ' [' + ProviderEpicId + '] - ' + Type end as Provider
,Type as ProviderType
,ProviderEpicId
,Npi 
,PrimarySpecialty
,case when Type in ('Nurse Practitioner','Physician Assistant','BHS Nurse Practitioner','BHS Physician Assistant','Nurse Anesthetist','Certified Nurse Midwife')
	then 1 else 0 end as APPFlag

into #prov

from Warehouse.dbo.ProviderDim

where 
IsCurrent = 1
and (IdType = 'EpicProviderId' or ProviderKey < 0)

create clustered index prov1 on #prov (ProviderDurableKey)





---- Charges
select top 10000
 t.ServiceDateKey
,t.PatientDurableKey
,t.ServiceProviderDurableKey
,t.BillingProviderDurableKey
,t.EncounterKey
,t.ServiceDepartmentKey
,t.BillingSystemType
,t.BillingAccountKey
,t.BillingProcedureCode
,SUM(t.Amount) as ChargeAmount
,SUM(t.BillingProcedureQuantity) as BillingProcedureQuantity
,SUM(case when t.Amount <> 0 then 1
		else 0 end) as ChargeCount

into #chargeDetail

from
Warehouse.dbo.BillingTransactionFact as t
inner join Warehouse.dbo.EncounterFact as ef on t.EncounterKey = ef.EncounterKey and ef.EncounterKey > 0
inner join Warehouse.dbo.DepartmentDim as saDep on t.DepartmentKey = saDep.DepartmentKey

where
t.TransactionType = 'Charge'
and t.ServiceDateKey between @startDateKey and @endDateKey
and saDep.ServiceAreaEpicId = '10'

group by
 t.ServiceDateKey
,t.PatientDurableKey
,t.ServiceProviderDurableKey
,t.BillingProviderDurableKey
,t.EncounterKey
,t.BillingSystemType
,t.BillingAccountKey
,t.BillingProcedureCode
,t.ServiceDepartmentKey


create nonclustered index cd1 on #chargeDetail (EncounterKey) 
	include (
	BillingSystemType, 
	ServiceDateKey, 
	PatientDurableKey, 
	ServiceProviderDurableKey, 
	BillingProviderDurableKey, 
	ServiceDepartmentKey,
	BillingAccountKey,
	ChargeAmount,
	BillingProcedureQuantity)


---- temp table to rank-order associated HARs
select  top 10000
 BillingAccountKey
,BillingSystemType
,EncounterKey
,ServiceProviderDurableKey
,BillingProviderDurableKey
,ServiceDateKey
,PatientDurableKey
,ServiceDepartmentKey
--,sum(ChargeAmount) as ChargeAmount
,ROW_NUMBER() over(partition by 
	 BillingSystemType
	,EncounterKey
	,ServiceProviderDurableKey
	,BillingProviderDurableKey
	,ServiceDateKey
	,PatientDurableKey
	,ServiceDepartmentKey
 order by sum(ChargeAmount) desc
 ) as Line

into #hars

from #chargeDetail 

group by
 BillingAccountKey
,BillingSystemType
,EncounterKey
,ServiceProviderDurableKey
,BillingProviderDurableKey
,ServiceDateKey
,PatientDurableKey
,ServiceDepartmentKey

create index har1 on #hars (BillingAccountKey)
	include (BillingSystemType
,EncounterKey
,ServiceProviderDurableKey
,BillingProviderDurableKey
,ServiceDateKey
,PatientDurableKey
,ServiceDepartmentKey
,Line)

---- aggregating charge info
select top 10000
 d.ServiceDateKey
,d.PatientDurableKey
,d.ServiceProviderDurableKey
,d.BillingProviderDurableKey
,d.EncounterKey
,d.ServiceDepartmentKey
,pb.BillingAccountKey as PBBillingAccountKey
,SUM(case when d.BillingSystemType = 'Professional' then d.ChargeAmount end) as PBChargeAmount
,SUM(case when d.BillingSystemType = 'Professional' then d.BillingProcedureQuantity end) as PBProcedureQuantity
,SUM(case when d.BillingSystemType = 'Professional' then d.ChargeCount end) as PBChargeCount
,STUFF((select ', ' + p.BillingProcedureCode
		from #chargeDetail as p
		where p.BillingSystemType = 'Professional'
		and p.EncounterKey = d.EncounterKey
		and p.ServiceProviderDurableKey = d.ServiceProviderDurableKey
		and p.BillingProviderDurableKey = d.BillingProviderDurableKey
		and p.ServiceDateKey = d.ServiceDateKey
		and p.PatientDurableKey = d.PatientDurableKey
		and p.ServiceDepartmentKey = d.ServiceDepartmentKey
		and p.BillingProcedureQuantity <> 0
		order by p.ChargeAmount desc
		for xml path ('')), 1, 2, '') as PBBillingCodes
,hb.BillingAccountKey as HBBillingAccountKey
,SUM(case when d.BillingSystemType = 'Hospital' then d.ChargeAmount end) as HBChargeAmount
,SUM(case when d.BillingSystemType = 'Hospital' then d.BillingProcedureQuantity end) as HBProcedureQuantity
,SUM(case when d.BillingSystemType = 'Hospital' then d.ChargeCount end) as HBChargeCount
,STUFF((select ', ' + h.BillingProcedureCode
		from #chargeDetail as h
		where h.BillingSystemType = 'Hospital'
		and h.EncounterKey = d.EncounterKey
		and h.ServiceProviderDurableKey = d.ServiceProviderDurableKey
		and h.BillingProviderDurableKey = d.BillingProviderDurableKey
		and h.ServiceDateKey = d.ServiceDateKey
		and h.PatientDurableKey = d.PatientDurableKey
		and h.ServiceDepartmentKey = d.ServiceDepartmentKey
		and h.BillingProcedureQuantity <> 0
		order by h.ChargeAmount desc
		for xml path ('')), 1, 2, '') as HBBillingCodes

into #chargeInfo

from
#chargeDetail as d
left outer join #hars as hb on
	hb.BillingSystemType = 'Hospital' and
	hb.EncounterKey = d.EncounterKey and
	hb.ServiceProviderDurableKey = d.ServiceProviderDurableKey and
	hb.BillingProviderDurableKey = d.BillingProviderDurableKey and
	hb.ServiceDateKey = d.ServiceDateKey and
	hb.PatientDurableKey = d.PatientDurableKey and
	hb.ServiceDepartmentKey = d.ServiceDepartmentKey and
	hb.Line = 1
left outer join #hars as pb on
	pb.BillingSystemType = 'Professional' and
	pb.EncounterKey = d.EncounterKey and
	pb.ServiceProviderDurableKey = d.ServiceProviderDurableKey and
	pb.BillingProviderDurableKey = d.BillingProviderDurableKey and
	pb.ServiceDateKey = d.ServiceDateKey and
	pb.PatientDurableKey = d.PatientDurableKey and
	pb.ServiceDepartmentKey = d.ServiceDepartmentKey and
	pb.Line = 1

group by
 d.ServiceDateKey
,d.PatientDurableKey
,d.ServiceProviderDurableKey
,d.BillingProviderDurableKey
,d.EncounterKey
,d.ServiceDepartmentKey
,hb.BillingAccountKey
,pb.BillingAccountKey

create nonclustered index ci1 on #chargeInfo (EncounterKey)
create nonclustered index ci2 on #chargeInfo (PatientDurableKey)
create nonclustered index ci3 on #chargeInfo (ServiceProviderDurableKey)
create nonclustered index ci4 on #chargeInfo (BillingProviderDurableKey)
create nonclustered index ci5 on #chargeInfo (ServiceDepartmentKey)
create nonclustered index ci6 on #chargeInfo (HBBillingAccountKey)
create nonclustered index ci7 on #chargeInfo (PBBillingAccountKey)
create nonclustered index ci8 on #chargeInfo (ServiceDateKey)


IF OBJECT_ID('tempdb..#chargeDetail') IS NOT NULL DROP TABLE #chargeDetail
IF OBJECT_ID('tempdb..#hars') IS NOT NULL DROP TABLE #hars



--pre-filter VisitFact by dates only for efficiency
IF OBJECT_ID('tempdb..#preVF') IS NOT NULL DROP TABLE #preVF
Select  top 10000*
into #preVF
from Warehouse.dbo.VisitFact as f
where
f.AppointmentDateKey between @startDateKey and @endDateKey
and f.Count = 1
and f.VisitType not in ('FINANCIAL NAVIGATOR','FINANCIAL NAVIGATOR TRANSFER') --Vincent made changes to hard delete profile dim tables as of 8/6/2018 
and f.EncounterType not in ('Erroneous Encounter', 'Erroneous Telephone Encounter') -- Vincent made changes to exclude the hospital encounter visit type as of 8/6/2018


--pre-filter EncounterFact by dates only for efficiency
IF OBJECT_ID('tempdb..#EF_exVF') IS NOT NULL DROP TABLE #EF_exVF
select  top 10000 ef.*
into #EF_exVF
from
Warehouse.dbo.EncounterFact as ef
left join Warehouse.dbo.VisitFact as vf_excl on vf_excl.EncounterKey = ef.EncounterKey
where
vf_excl.EncounterKey is null
and ef.EncounterKey > 0
and ef.DateKey between @startDateKey and @endDateKey
and ef.Count = 1
and ef.VisitType not in ('FINANCIAL NAVIGATOR','FINANCIAL NAVIGATOR TRANSFER', '*Unspecified') --Vincent made changes to hard delete profile dim tables as of 8/6/2018 
and ef.Type not in ('Erroneous Encounter', 'Erroneous Telephone Encounter') -- Vincent made changes to exclude the hospital encounter visit type as of 8/6/2018



------- Encounters

select top 10000
 'Appointments' as RecordType
,replace(f.IdType, 'EpicEncounterCsnId:', '') as AppointmentType
,f.EncounterEpicCsn
,ef.PatientClass
,vp1.Provider as AppointmentProvider
,vp1.ProviderType as ApptProviderType
,vp1.PrimarySpecialty as ApptProviderPrimarySpecialty
,null as ChargeServiceProvider
,null as ChargeServiceProviderType
,null as ChargeServiceProviderPrimarySpecialty
,null as ChargeBillingProvider
,null as ChargeBillingProviderType
,null as ChargeBillingProviderPrimarySpecialty
,vp1.Provider as ProvidersForOrSearch
,case when vp1.APPFlag > 0 then 'Y' else 'N' end as APPServiceYN
,dep.ServiceDepartment
,dep.ServiceDepartmentId
,dep.Location
,dep.LocationEpicId
,null as ChargeServiceDepartment
,null as ChargeServiceDepartmentId
,null as ChargeLocation
,null as ChargeLocationEpicId
,a.AppointmentStatus AS WH_AppointmentStatus
,f.EncounterType
,f.VisitType
,f.FinancialClass as VisitFinancialClass
,f.AppointmentDateKey as EncounterOrServiceDateKey
,f.AppointmentTimeOfDayKey as AppointmentTimeHMM
,dpt.PrimaryMrn
,f.HospitalAccountEpicId
,f.PrimaryProfessionalAccountEpicId
,f.Complete as CompleteFlag
,case when closed = 1 then 'Y' when closed is null then 'N/A' else 'N' end as EncounterClosedYN 
,f.ClosedDateKey
,f.Count as AppointmentCount
,null as PBChargeAmount
,null as PBChargeCount
,null as PBProcedureQuantity
,null as PBBillingCodes
,null as HBChargeAmount
,null as HBChargeCount
,null as HBProcedureQuantity
,null as HBBillingCodes
,null as TotalChargeAmount
,case when a.WH_EncounterCount is null then null
	when i.EncHBChargeCount > 0 then
		case when i.EncPBChargeCount > 0 then '2 - Both HB and PB'
		else '1 - HB Only' End
	else case when i.EncPBChargeCount > 0 then '1 - PB Only'
		else '0 - Neither HB nor PB' end
	end as EncounterCSNAssociatedChargesCategory
,a.WH_AppointmentStatusWithSort
,a.WH_StatusGroupingNumber
,a.WH_EncounterCount
,case when f.EncounterType not in ('Hospital Encounter') then a.WH_EncounterCount else 0 end as WH_Closeable_Encounters
,case when f.EncounterType not in ('Hospital Encounter') and f.Closed = 0 then a.WH_EncounterCount else 0 end as WH_OpenEncounters

from
#preVF as f
inner join Warehouse.dbo.EncounterFact as ef on f.EncounterKey = ef.EncounterKey
inner join #prov as vp1 on f.PrimaryVisitProviderDurableKey = vp1.ProviderDurableKey
inner join #svcDep as dep on f.DepartmentKey = dep.ServiceDepartmentKey
inner join #apptPD as a on f.AppointmentProfileKey = a.AppointmentProfileKey
inner join Warehouse.dbo.PatientDim as dpt on f.PatientDurableKey = dpt.DurableKey and dpt.IsCurrent = 1 
left outer join (select EncounterKey, SUM(PBChargeCount) as EncPBChargeCount, SUM(HBChargeCount) as EncHBChargeCount
	from #chargeInfo
	group by EncounterKey
	) as i on f.EncounterKey = i.EncounterKey


union all


----- adding charge info

select top 10000
'Charges' as RecordType
,replace(f.IdType, 'EpicEncounterCsnId:', '') as AppointmentType
,f.EncounterEpicCsn
,ef.PatientClass
,vp1.Provider as AppointmentProvider
,vp1.ProviderType as ApptProviderType
,vp1.PrimarySpecialty as ApptProviderPrimarySpecialty
,sprov.Provider
,sprov.ProviderType
,sprov.PrimarySpecialty
,bprov.Provider
,bprov.ProviderType
,bprov.PrimarySpecialty
,vp1.Provider + '; ' + sprov.Provider + '; ' + bprov.Provider --as ProvidersForOrSearch
,case when vp1.APPFlag + sprov.APPFlag + bprov.APPFlag > 0 then 'Y' else 'N' end 
,adep.ServiceDepartment --as ServiceDepartment
,adep.ServiceDepartmentId
,adep.Location
,adep.LocationEpicId
,dep.ServiceDepartment --as ServiceDepartment
,dep.ServiceDepartmentId
,dep.Location
,dep.LocationEpicId
,a.AppointmentStatus AS WH_AppointmentStatus
,f.EncounterType
,f.VisitType
,f.FinancialClass
,c.ServiceDateKey
,f.AppointmentTimeOfDayKey as AppointmentTimeHMM
,dpt.PrimaryMrn
,hbaf.AccountEpicId --HB
,pbaf.AccountEpicId --PB
,f.Complete
,case when f.closed = 1 then 'Y' when f.closed is null then 'N/A' else 'N' end as EncounterClosedYN 
,f.ClosedDateKey
,0 as AppointmentCount
,c.PBChargeAmount
,c.PBChargeCount
,c.PBProcedureQuantity
,c.PBBillingCodes
,c.HBChargeAmount
,c.HBChargeCount
,c.HBProcedureQuantity
,c.HBBillingCodes
,coalesce(c.PBChargeAmount, 0) + coalesce(c.HBChargeAmount, 0) as TotalChargeAmount
,case when SUM(HBChargeCount) OVER (PARTITION BY c.EncounterKey) > 0 then
		case when SUM(PBChargeCount) OVER (PARTITION BY c.EncounterKey) > 0 then '2 - Both HB and PB'
		else '1 - HB Only' End
	else case when SUM(PBChargeCount) OVER (PARTITION BY c.EncounterKey) > 0 then '1 - PB Only'
		else '0 - Neither HB nor PB' end
	end as EncounterCSNAssociatedChargesCategory
,a.WH_AppointmentStatusWithSort
,a.WH_StatusGroupingNumber
,0 AS WH_EncounterCount
,0 AS WH_Closeable_Encounters
,0 AS WH_OpenEncounters

from
#chargeInfo as c
inner join #preVF as f on c.EncounterKey = f.EncounterKey and f.EncounterKey > 0 
inner join #apptPD as a on f.AppointmentProfileKey = a.AppointmentProfileKey
inner join Warehouse.dbo.EncounterFact as ef on f.EncounterKey = ef.EncounterKey and f.EncounterKey > 0
inner join #prov as sprov on c.ServiceProviderDurableKey = sprov.ProviderDurableKey
inner join #prov as bprov on c.BillingProviderDurableKey = bprov.ProviderDurableKey
inner join #prov as vp1 on f.PrimaryVisitProviderDurableKey = vp1.ProviderDurableKey
inner join #svcDep as dep on c.ServiceDepartmentKey = dep.ServiceDepartmentKey
inner join #svcDep as adep on f.DepartmentKey = adep.ServiceDepartmentKey
inner join Warehouse.dbo.PatientDim as dpt on c.PatientDurableKey = dpt.DurableKey and dpt.IsCurrent = 1 
left outer join Warehouse.dbo.BillingAccountFact as hbaf on c.HBBillingAccountKey = hbaf.BillingAccountKey and (c.HBBillingAccountKey is null or c.HBBillingAccountKey > 0)
left outer join Warehouse.dbo.BillingAccountFact as pbaf on c.PBBillingAccountKey = pbaf.BillingAccountKey and (c.PBBillingAccountKey is null or c.PBBillingAccountKey > 0)


--Add in non F2F encounters excluded by warehouse visit fact logic that should otherwise be included
union all

--encounters

select top 10000
 'Appointments' as RecordType
,replace(ef.IdType, 'EpicEncounterCsnId:', '') as AppointmentType
,ef.EncounterEpicCsn
,ef.PatientClass
,vp1.Provider as AppointmentProvider
,vp1.ProviderType as ApptProviderType
,vp1.PrimarySpecialty as ApptProviderPrimarySpecialty
,null as ChargeServiceProvider
,null as ChargeServiceProviderType
,null as ChargeServiceProviderPrimarySpecialty
,null as ChargeBillingProvider
,null as ChargeBillingProviderType
,null as ChargeBillingProviderPrimarySpecialty
,vp1.Provider as ProvidersForOrSearch
,case when vp1.APPFlag > 0 then 'Y' else 'N' end as APPServiceYN
,dep.ServiceDepartment
,dep.ServiceDepartmentId
,dep.Location
,dep.LocationEpicId
,null as ChargeServiceDepartment
,null as ChargeServiceDepartmentId
,null as ChargeLocation
,null as ChargeLocationEpicId
,null as WH_AppointmentStatus  --Insufficient Data
,ef.Type as EncounterType
,ef.VisitType
,null as VisitFinancialClass  --Insufficient Data
,ef.DateKey as EncounterOrServiceDateKey
,null as AppointmentTimeHMM  --Insufficient Data
,dpt.PrimaryMrn
,null as  HospitalAccountEpicId  --Insufficient Data
,null as  PrimaryProfessionalAccountEpicId    --Insufficient Data
,null as CompleteFlag  --Insufficient Data
,null as EncounterClosedYN   --Insufficient Data
,null as ClosedDate  --Insufficient Data
,ef.Count as AppointmentCount
,null as PBChargeAmount
,null as PBChargeCount
,null as PBProcedureQuantity
,null as PBBillingCodes
,null as HBChargeAmount
,null as HBChargeCount
,null as HBProcedureQuantity
,null as HBBillingCodes
,null as TotalChargeAmount
,case 
	when i.EncHBChargeCount > 0 then
		case when i.EncPBChargeCount > 0 then '2 - Both HB and PB'
		else '1 - HB Only' End
	else case when i.EncPBChargeCount > 0 then '1 - PB Only'
		else '0 - Neither HB nor PB' end
	end as EncounterCSNAssociatedChargesCategory
, null AS WH_AppointmentStatusWithSort  --Insufficient Data
, null AS WH_StatusGroupingNumber  --Insufficient Data
, 1 as WH_EncounterCount --defaulting to 1 in absence of appointment status
, 0 as WH_Closeable_Encounters  --Insufficient Data
, 0 as WH_OpenEncounters  --Insufficient Data


from
#EF_exVF as ef
inner join #prov as vp1 on ef.ProviderDurableKey = vp1.ProviderDurableKey
inner join #svcDep as dep on ef.DepartmentKey = dep.ServiceDepartmentKey
inner join Warehouse.dbo.PatientDim as dpt on ef.PatientDurableKey = dpt.DurableKey and dpt.IsCurrent = 1 
left outer join (
	select 
	EncounterKey
	, SUM(PBChargeCount) as EncPBChargeCount
	, SUM(HBChargeCount) as EncHBChargeCount
	from #chargeInfo
	group by EncounterKey
	) as i on ef.EncounterKey = i.EncounterKey


union all


--charges for non VF table encounters

select top 10000
'Charges' as RecordType
,replace(ef.IdType, 'EpicEncounterCsnId:', '') as AppointmentType
,ef.EncounterEpicCsn
,ef.PatientClass
,vp1.Provider as AppointmentProvider
,vp1.ProviderType as ApptProviderType
,vp1.PrimarySpecialty as ApptProviderPrimarySpecialty
,sprov.Provider
,sprov.ProviderType
,sprov.PrimarySpecialty
,bprov.Provider
,bprov.ProviderType
,bprov.PrimarySpecialty
,vp1.Provider + '; ' + sprov.Provider + '; ' + bprov.Provider --as ProvidersForOrSearch
,case when vp1.APPFlag + sprov.APPFlag + bprov.APPFlag > 0 then 'Y' else 'N' end 
,adep.ServiceDepartment --as ServiceDepartment
,adep.ServiceDepartmentId
,adep.Location
,adep.LocationEpicId
,dep.ServiceDepartment --as ServiceDepartment
,dep.ServiceDepartmentId
,dep.Location
,dep.LocationEpicId
,null WH_AppointmentStatus --Insufficient Data
,ef.Type as EncounterType
,ef.VisitType
,null FinancialClass  --Insufficient Data
,c.ServiceDateKey
,0 as AppointmentTimeHMM --Insufficient Data
,dpt.PrimaryMrn
,hbaf.AccountEpicId --HB
,pbaf.AccountEpicId --PB
,null as Complete --Insufficient Data
,null as EncounterClosedYN --Insufficient Data
,null as ClosedDateKey --Insufficient Data
,0 as AppointmentCount
,c.PBChargeAmount
,c.PBChargeCount
,c.PBProcedureQuantity
,c.PBBillingCodes
,c.HBChargeAmount
,c.HBChargeCount
,c.HBProcedureQuantity
,c.HBBillingCodes
,coalesce(c.PBChargeAmount, 0) + coalesce(c.HBChargeAmount, 0) as TotalChargeAmount
,case when SUM(HBChargeCount) OVER (PARTITION BY c.EncounterKey) > 0 then
		case when SUM(PBChargeCount) OVER (PARTITION BY c.EncounterKey) > 0 then '2 - Both HB and PB'
		else '1 - HB Only' End
	else case when SUM(PBChargeCount) OVER (PARTITION BY c.EncounterKey) > 0 then '1 - PB Only'
		else '0 - Neither HB nor PB' end
	end as EncounterCSNAssociatedChargesCategory
,null AS WH_AppointmentStatusWithSort --Insufficient Data
,null AS WH_StatusGroupingNumber --Insufficient Data
,0 as WH_EncounterCount
,0 as WH_Closeable_Encounters
,0 as WH_OpenEncounters

from
#chargeInfo as c
inner join #EF_exVF as ef on c.EncounterKey = ef.EncounterKey
inner join #prov as sprov on c.ServiceProviderDurableKey = sprov.ProviderDurableKey
inner join #prov as bprov on c.BillingProviderDurableKey = bprov.ProviderDurableKey
inner join #prov as vp1 on ef.ProviderDurableKey = vp1.ProviderDurableKey
inner join #svcDep as dep on c.ServiceDepartmentKey = dep.ServiceDepartmentKey
inner join #svcDep as adep on ef.DepartmentKey = adep.ServiceDepartmentKey
inner join Warehouse.dbo.PatientDim as dpt on c.PatientDurableKey = dpt.DurableKey and dpt.IsCurrent = 1 
left outer join Warehouse.dbo.BillingAccountFact as hbaf on c.HBBillingAccountKey = hbaf.BillingAccountKey and (c.HBBillingAccountKey is null or c.HBBillingAccountKey > 0)
left outer join Warehouse.dbo.BillingAccountFact as pbaf on c.PBBillingAccountKey = pbaf.BillingAccountKey and (c.PBBillingAccountKey is null or c.PBBillingAccountKey > 0)


-- cleanup
IF OBJECT_ID('tempdb..#pos') IS NOT NULL DROP TABLE #pos
IF OBJECT_ID('tempdb..#prov') IS NOT NULL DROP TABLE #prov
IF OBJECT_ID('tempdb..#svcDep') IS NOT NULL DROP TABLE #svcDep
IF OBJECT_ID('tempdb..#apptPD') IS NOT NULL DROP TABLE #apptPD
IF OBJECT_ID('tempdb..#chargeInfo') IS NOT NULL DROP TABLE #chargeInfo
IF OBJECT_ID('tempdb..#preVF') IS NOT NULL DROP TABLE #preVF
IF OBJECT_ID('tempdb..#EF_exVF') IS NOT NULL DROP TABLE #EF_exVF
;