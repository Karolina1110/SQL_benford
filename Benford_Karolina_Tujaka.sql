use ML;
go

drop procedure if exists [BenfordFraud].getFraudData
go
create procedure [BenfordFraud].getFraudData
as
begin
	select VendorNumber, VoucherNumber, CheckNumber, InvoiceNumber, InvoiceDate, PaymentDate, DueDate, InvoiceAmount
	  from [BenfordFraud].[Invoices];
end;
go

-- Generates the Digits and Frequency for each vendor
drop function if exists [BenfordFraud].VendorInvoiceDigits
go
create function [BenfordFraud].VendorInvoiceDigits (@VendorNumber varchar(10) = null)
returns table
as
return
	with f as (
		select VendorNumber
			 , InvoiceAmount
			 , round(case
					when InvoiceAmount >= 1000000000 then InvoiceAmount / 1000000000
					when InvoiceAmount >= 100000000 then InvoiceAmount / 100000000
					when InvoiceAmount >= 10000000 then InvoiceAmount / 10000000
					when InvoiceAmount >= 1000000 then InvoiceAmount / 1000000
					when InvoiceAmount >= 100000 then InvoiceAmount / 100000
					when InvoiceAmount >= 10000 then InvoiceAmount / 10000
					when InvoiceAmount >= 1000 then InvoiceAmount / 1000
					when InvoiceAmount >= 100 then InvoiceAmount / 100
					when InvoiceAmount >= 10 then InvoiceAmount / 10
					when InvoiceAmount < 10 then InvoiceAmount
				end, 0, 1) as Digits
			, count(*) over(partition by VendorNumber) as #Transactions
		  from [BenfordFraud].[Invoices]
	)
	select VendorNumber, Digits, count(*) as Freq
	  from f
	where #Transactions > 2 and InvoiceAmount > 0 and (VendorNumber = @VendorNumber or @VendorNumber IS NULL)
	group by VendorNumber, Digits
go

--test
SELECT * FROM [BenfordFraud].VendorInvoiceDigits(105436)

drop procedure if exists [BenfordFraud].getPotentialFraudulentVendors;
go

create procedure [BenfordFraud].getPotentialFraudulentVendors (@threshold float = 0.1)
as
begin
	-- Use Benford law to get the potential fraud vendors.
	exec sp_execute_external_script
		  @language = N'Python',
		  @script = N'
import pandas as pd
import pyodbc 
import math
import numpy as np
from scipy.stats import chisquare

dd = pd.pivot_table(InputDataSet, values="Freq", index=["VendorNumber"], columns=["Digits"])

dd = dd.rename_axis(None, axis=1).reset_index()

p=[0,1,2,3,4,5,6,7,8]
for v in [1,2,3,4,5,6,7,8,9]:
	p[v-1] = math.log10(1 + 1 / (v)) / math.log10(10)

p = np.array(p)

chi = []
for i in np.array(range(dd.shape[0])):
	ddi = np.array(dd.iloc[i,1:])
	_,tmp = chisquare(ddi, np.sum(ddi)*p)
	chi.append(tmp)

OutputDataSet = pd.concat([dd, pd.DataFrame(chi)], axis = 1)
OutputDataSet.columns =["VendorNumber", "Digit1" , "Digit2" , "Digit3" , "Digit4" , "Digit5" , "Digit6" , "Digit7" , "Digit8" , "Digit9" , "Pvalue" ]
OutputDataSet = OutputDataSet[OutputDataSet.Pvalue < threshold]

		  ',
		  @input_data_1 = N'
	select VendorNumber, CAST(Digits AS INT) AS Digits, Freq
	  from [BenfordFraud].VendorInvoiceDigits(default)
	order by VendorNumber asc, Digits asc;
		  ',
		  @params = N'@threshold float',
		  @threshold = @threshold
	with result sets (( VendorNumber varchar(10),
	   Digit1 int, Digit2 int, Digit3 int, Digit4 int, Digit5 int, Digit6 int, Digit7 int, Digit8 int, Digit9 int,
	   Pvalue float));
end;

exec [BenfordFraud].getPotentialFraudulentVendors 0.99

go
drop procedure if exists [BenfordFraud].getVendorInvoiceDigits;
go
create procedure [BenfordFraud].getVendorInvoiceDigits (@VendorNumber varchar(10))
as
begin
	-- Produces plot for a specific vendor showing the distribution of invoice amount digits (Actual) vs. Benford distribution for the digit (Expected)
	exec sp_execute_external_script
		  @language = N'Python',
		  @script = N'
import pandas as pd
import pyodbc 
import math
import numpy as np
import matplotlib.pyplot as plt
import os

qq = list(InputDataSet.iloc[:,0])

exp=[0,1,2,3,4,5,6,7,8]
num = [1,2,3,4,5,6,7,8,9]
for v in num:
	exp[v-1] = 100*(math.log10(1 + 1 / (v)) / math.log10(10))

exp = np.array(exp)

act = []
for i in num:
	tmp = 100*qq[i-1]/np.sum(qq)
	act.append(tmp)

act = np.array(act)

pp = pd.DataFrame({"num": num, "Actual":act, "Expected":exp})

plt.bar(num, exp, color = "blue", alpha = 0.5, label = "Expected")
plt.bar(num, act, color = "green", alpha = 0.5, label = "Actual")
plt.title("Distribution of Leading Digits in Invoices")
plt.xlabel("Digits")
plt.ylabel("Percent")
plt.legend()
path = f"D:\SQL\MSSQL15.MSSQLSERVER\PYTHON_SERVICES\{vendor}.png"
plt.savefig(path)

v = np.array(range(1,73))

OutputDataSet = pd.DataFrame(v)
		  ',
		  @input_data_1 = N'select Freq from [BenfordFraud].VendorInvoiceDigits(@vendor) order by Digits;',
		  @params = N'@vendor varchar(10)',
		  @vendor = @VendorNumber
	with result sets(([chart] varbinary(max)));
end;
go

drop procedure if exists [BenfordFraud].getVendorInvoiceDigitsPlots;
go
create procedure [BenfordFraud].getVendorInvoiceDigitsPlots (@threshold float = 0.1)
as
begin
	-- Produces plots for all vendors suspected of fraud showing
	-- the distribution of invoice amount digits (Actual) vs. Benford distribution for the digit (Expected)
	create table #v ( VendorNumber varchar(10),
	   Digit1 int, Digit2 int, Digit3 int, Digit4 int, Digit5 int, Digit6 int, Digit7 int, Digit8 int, Digit9 int,
	   Pvalue float);

	insert into #v exec [BenfordFraud].getPotentialFraudulentVendors @threshold;
	truncate table [BenfordFraud].FraudulentVendorsPlots;

	declare @p cursor, @vendor varchar(10);
	set @p = cursor fast_forward for select VendorNumber from #v;
	open @p;
	while(1=1)
	begin
		fetch @p into @vendor;
		if @@fetch_status < 0 break;

		insert into [BenfordFraud].[FraudulentVendorsPlots] (Plot)
		exec [BenfordFraud].getVendorInvoiceDigits @vendor;

		update [BenfordFraud].[FraudulentVendorsPlots] set VendorNumber = @vendor where VendorNumber IS NULL;
	end;
	deallocate @p;
end;
go

exec [BenfordFraud].getVendorInvoiceDigitsPlots 

select *
from[BenfordFraud].[FraudulentVendorsPlots] 

drop procedure if exists [BenfordFraud].getPotentialFraudulentVendorsList
go
create procedure [BenfordFraud].getPotentialFraudulentVendorsList (@threshold float)
as
begin
	-- Optimized version of the proc that uses staging table for the fraud data
	select fv.*, fvp.Plot
	  from [BenfordFraud].[FraudulentVendors] as fv
	  join [BenfordFraud].[FraudulentVendorsPlots] as fvp
		on fvp.VendorNumber = fv.VendorNumber;
end;
go


