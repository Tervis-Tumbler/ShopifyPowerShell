#Requires -Modules WebServicesPowerShellProxyBuilder

function Set-ShopifyCredential {
    param (
        [Parameter(Mandatory)]$Credential
    )
    $Script:Credential = $Credential
}
function Get-ShopifyCredential {
    if ($Script:Credential) {
        $Script:Credential
    } else {
        Throw "You need to call Set-ShopifyCredential"
    }
}
function Invoke-ShopifyAPIFunction{
    [cmdletbinding()]
    param(
        $HttpMethod,
        $ShopName,
        $Resource,
        $Subresource,
        $Body
        )
    
    $URIRoot = "https://$($Credential.UserName):$($Credential.Password)@$ShopName.myshopify.com/admin/$Resource"

    if ($Subresource){
        $URI = $URIRoot + "/$Subresource" + ".json"
    } else {
        $URI = $URIRoot + ".json"
    }    
    

    $Response = if ($Body) {
        Invoke-RestMethod -Credential $Credential -Method $HttpMethod -Uri $URI -Body $Body
    } else {
        Invoke-RestMethod -Credential $Credential -Method $HttpMethod -Uri $URI 
    }
    
    $Response
}

function Get-ShopifyInventoryItems{
    [cmdletbinding()]
    param(
        [Parameter(mandatory)]$ShopName,
        [Parameter(mandatory)]$ItemIDsSeparatedByCommas
    )
    #$ItemIDsSeparatedByCommas needs to be refactored.

    $HttpMethod = "Get"
    $Resource = "inventory_items.json?ids=$ItemIDsSeparatedByCommas"

    Invoke-ShopifyAPIFunction -HttpMethod $HttpMethod -Resource $Resource -ShopName $ShopName
}

function Get-ShopifyShop{
    [cmdletbinding()]
    param(
        [Parameter(mandatory)]$ShopName
    )

    $HttpMethod = "Get"
    $Resource = "shop"

    Invoke-ShopifyAPIFunction -HttpMethod $HttpMethod -Resource $Resource -ShopName $ShopName
}

function Get-ShopifyProducts{
    [cmdletbinding()]
    param(
        [parameter(mandatory)]$ShopName
    )

    $HttpMethod = "Get"
    $Resource = "products"

    Invoke-ShopifyAPIFunction -HttpMethod $HttpMethod -Resource $Resource -ShopName $ShopName
}

function New-ShopifyProduct{
    [cmdletbinding()]
    param(
        [parameter(mandatory)]$ShopName,
        [parameter(mandatory)]$Title,
        [parameter(mandatory)]$Description,
        [parameter(mandatory)]$EBSItemNumber,
        [parameter(mandatory)]$UPC,
        [parameter(mandatory)]$Price,
        $InventoryQuantity = 0
    )

    $HttpMethod = "Post"
    $Resource = "products"

    $Body = @"
{"product": {
"title": "$Title",
"body_html": "$Description",
"variants: [{
"price":"$Price",
"sku":"$EBSItemNumber",
"barcode":"$UPC"
"inventory_quantity":"$InventoryQuantity"
}]}}    
"@
}